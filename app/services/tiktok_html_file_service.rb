class TiktokHtmlFileService
  require 'nokogiri'
  require 'json'
  require 'open3'

  COMMENT_COUNT_PER_PAGE = 20
  MAX_COMMENT_PAGES = 5    # tối đa 100 comments (5 trang × 20)
  MAX_STATS_FETCH    = 100 # fetch stats cho tất cả commenters

  # ─── Public: bulk mode ──────────────────────────────────────────────────
  # Returns top-2 most-viewed posts' commenters (no stat enrichment).
  # { success:, username:, display_name:, videos: [{url:, play_count:}], commenters_raw: [{username:, url:, display_name:}] }
  def get_top2_posts_info(url)
    username = extract_username(url)
    tmp_file = Rails.root.join("tmp", "tiktok_#{username}_#{Time.now.to_i}.html")

    Rails.logger.info "=== [Bulk] Downloading TikTok HTML for: #{username} ==="
    success = download_with_curl(url, tmp_file)

    unless success && File.exist?(tmp_file)
      return { success: false, error: "Không thể tải trang TikTok: #{url}" }
    end

    html = File.read(tmp_file)
    File.delete(tmp_file) if File.exist?(tmp_file)

    parsed = parse_html(html, url, username)
    return { success: false, error: parsed[:error] } unless parsed[:success]

    sec_uid = parsed[:sec_uid]
    items   = fetch_video_list(username, sec_uid)

    # Pick top 2 by view count
    top2 = items
      .sort_by { |v| -v.dig('stats', 'playCount').to_i }
      .first(2)

    all_commenters = []
    videos_info    = []

    top2.each do |video|
      video_id   = video['id'] || video['itemId']
      play_count = video.dig('stats', 'playCount').to_i
      next unless video_id

      video_url = "https://www.tiktok.com/@#{username}/video/#{video_id}"
      videos_info << { url: video_url, play_count: play_count }

      # Fetch ALL comment pages (no limit)
      commenters = fetch_all_commenters(video_id, username, max_pages: 9999)
      all_commenters.concat(commenters)
    end

    all_commenters = all_commenters.uniq { |c| c[:username] }
    Rails.logger.info "[Bulk] #{username}: #{all_commenters.size} unique commenters from #{videos_info.size} video(s)"

    {
      success:        true,
      username:       username,
      display_name:   parsed[:display_name],
      videos:         videos_info,
      commenters_raw: all_commenters
    }
  rescue => e
    File.delete(tmp_file) if tmp_file && File.exist?(tmp_file)
    Rails.logger.error "TiktokHtmlFileService#get_top2_posts_info Error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
    { success: false, error: e.message }
  end

  # ─── Public: single mode ─────────────────────────────────────────────────
  def get_info(url)
    username = extract_username(url)
    tmp_file = Rails.root.join("tmp", "tiktok_#{username}_#{Time.now.to_i}.html")

    Rails.logger.info "=== Downloading TikTok HTML for: #{username} ==="
    success = download_with_curl(url, tmp_file)

    unless success && File.exist?(tmp_file)
      return { success: false, error: "Không thể tải trang TikTok. Vui lòng thử lại." }
    end

    html = File.read(tmp_file)
    Rails.logger.info "HTML downloaded: #{html.size} bytes"

    result = parse_html(html, url, username)
    File.delete(tmp_file) if File.exist?(tmp_file)
    Rails.logger.info "Temp file deleted."

    return result unless result[:success]

    target_post = get_target_post_with_commenters(username, result[:sec_uid])
    result.merge(target_post)
  rescue => e
    File.delete(tmp_file) if tmp_file && File.exist?(tmp_file)
    Rails.logger.error "TiktokHtmlFileService Error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
    { success: false, error: e.message }
  end

  private

  # Chọn post target: ưu tiên pinned → nhiều view nhất → fallback embed page
  def get_target_post_with_commenters(username, sec_uid)
    video_id, video_url, reason = pick_target_video(username, sec_uid)

    if video_id.nil?
      Rails.logger.warn "No target video found for #{username}"
      return { target_post_url: nil, commenters: [] }
    end

    Rails.logger.info "Target video [#{reason}]: #{video_id}"

    commenters = fetch_all_commenters(video_id, username)
    commenters = enrich_with_stats(commenters)

    { target_post_url: video_url, commenters: commenters }
  rescue => e
    Rails.logger.error "get_target_post_with_commenters error: #{e.message}"
    { target_post_url: nil, commenters: [] }
  end

  # Trả về [video_id, url, reason]
  # Dùng item_list API (cần secUid) → có isTop + playCount đầy đủ
  def pick_target_video(username, sec_uid)
    items = fetch_video_list(username, sec_uid)
    Rails.logger.info "Video list from API: #{items.size} items"

    if items.any?
      # Ưu tiên 1: video được ghim (isTop = 1)
      pinned = items.find { |v| v['isTop'].to_i == 1 }
      if pinned
        id = pinned['id'] || pinned['itemId']
        Rails.logger.info "Found PINNED video: #{id}"
        return [id, "https://www.tiktok.com/@#{username}/video/#{id}", 'PINNED']
      end

      # Ưu tiên 2: video có nhiều lượt xem nhất
      best = items.max_by { |v| v.dig('stats', 'playCount').to_i }
      if best
        id    = best['id'] || best['itemId']
        plays = best.dig('stats', 'playCount').to_i
        Rails.logger.info "Found MOST_VIEWED video: #{id} (#{plays} plays)"
        return [id, "https://www.tiktok.com/@#{username}/video/#{id}", "MOST_VIEWED(#{plays} plays)"]
      end
    end

    # Fallback: embed page → video có ID lớn nhất (mới nhất)
    Rails.logger.warn "item_list API returned nothing, falling back to embed page"
    embed_file = Rails.root.join("tmp", "tiktok_embed_#{username}_#{Time.now.to_i}.html")
    embed_url  = "https://www.tiktok.com/embed/@#{username}"
    success    = download_with_curl(embed_url, embed_file, referer: "https://www.google.com/")

    if success && File.exist?(embed_file)
      embed_html = File.read(embed_file)
      File.delete(embed_file) if File.exist?(embed_file)
      escaped   = Regexp.escape(username)
      video_ids = embed_html.scan(%r{tiktok\.com/@#{escaped}/video/(\d+)}).flatten.uniq
      unless video_ids.empty?
        id = video_ids.max_by(&:to_i)
        return [id, "https://www.tiktok.com/@#{username}/video/#{id}", 'LATEST_FALLBACK']
      end
    end

    [nil, nil, nil]
  end

  # Gọi TikTok item_list API để lấy danh sách video với isTop + playCount
  def fetch_video_list(username, sec_uid)
    return fetch_video_list_via_html(username) if sec_uid.blank?

    api_url = "https://www.tiktok.com/api/post/item_list/" \
              "?secUid=#{sec_uid}&count=35&cursor=0&aid=1988"
    tmp = Rails.root.join("tmp", "tiktok_items_#{username}_#{Time.now.to_i}.json")

    success = download_with_curl(
      api_url, tmp,
      referer: "https://www.tiktok.com/@#{username}",
      accept:  "application/json, text/plain, */*"
    )

    unless success && File.exist?(tmp)
      Rails.logger.warn "item_list API download failed"
      return fetch_video_list_via_html(username)
    end

    raw = File.read(tmp)
    File.delete(tmp) if File.exist?(tmp)

    begin
      j = JSON.parse(raw)
      items = j['itemList'] || j['items'] || []
      Rails.logger.info "item_list API: #{items.size} videos, status=#{j['statusCode']}"
      return items if items.any?
    rescue JSON::ParserError => e
      Rails.logger.warn "item_list API JSON parse error: #{e.message}"
    end

    # Nếu API không trả về gì, fallback sang scrape HTML profile
    fetch_video_list_via_html(username)
  end

  # Fallback: scrape video IDs từ embed page, trả về array giả với chỉ id (không có stats)
  def fetch_video_list_via_html(username)
    embed_file = Rails.root.join("tmp", "tiktok_embed_#{username}_#{Time.now.to_i}.html")
    embed_url  = "https://www.tiktok.com/embed/@#{username}"
    success    = download_with_curl(embed_url, embed_file, referer: "https://www.google.com/")

    return [] unless success && File.exist?(embed_file)

    embed_html = File.read(embed_file)
    File.delete(embed_file) if File.exist?(embed_file)
    escaped   = Regexp.escape(username)
    video_ids = embed_html.scan(%r{tiktok\.com/@#{escaped}/video/(\d+)}).flatten.uniq

    # Trả về format giống item_list nhưng không có stats
    video_ids.map { |vid| { 'id' => vid, 'stats' => { 'playCount' => 0 }, 'isTop' => 0 } }
  end

  # Trả về [{username:, url:, display_name:}]
  def fetch_all_commenters(video_id, username, max_pages: MAX_COMMENT_PAGES)
    all = []
    cursor = 0
    page   = 0

    loop do
      comment_file = Rails.root.join("tmp", "tiktok_comments_#{video_id}_p#{page}.json")
      api_url = "https://www.tiktok.com/api/comment/list/" \
                "?aweme_id=#{video_id}&count=#{COMMENT_COUNT_PER_PAGE}&cursor=#{cursor}&aid=1988"

      success = download_with_curl(
        api_url, comment_file,
        referer: "https://www.tiktok.com/@#{username}/video/#{video_id}",
        accept:  "application/json, text/plain, */*"
      )

      unless success && File.exist?(comment_file)
        Rails.logger.warn "Comment API failed (page #{page})"
        break
      end

      raw = File.read(comment_file)
      File.delete(comment_file) if File.exist?(comment_file)

      begin
        j = JSON.parse(raw)
      rescue JSON::ParserError
        Rails.logger.warn "Comment API non-JSON response"
        break
      end

      comments = j["comments"] || []
      has_more = j["has_more"].to_i == 1

      comments.each do |c|
        uid      = c.dig("user", "unique_id").to_s.strip
        nickname = c.dig("user", "nickname").to_s.strip
        next unless uid.present?
        all << { username: uid, url: "https://www.tiktok.com/@#{uid}", display_name: nickname }
      end

      Rails.logger.info "Comments page #{page}: got #{comments.size}, has_more=#{has_more}"
      page += 1
      break unless has_more && comments.any? && page < max_pages
      cursor = j["cursor"].to_i
    end

    Rails.logger.info "Total commenters: #{all.size}"
    # Dedup by username
    all.uniq { |c| c[:username] }
  end

  def enrich_with_stats(commenters)
    limited = commenters.first(MAX_STATS_FETCH)
    Rails.logger.info "Fetching stats for #{limited.size}/#{commenters.size} commenters..."

    limited.map.with_index(1) do |commenter, i|
      Rails.logger.info "  [#{i}/#{limited.size}] @#{commenter[:username]}"
      stats = fetch_user_stats(commenter[:username], commenter[:url])
      # Delay ngẫu nhiên để tránh TikTok rate-limit (không delay sau item cuối)
      sleep(rand(1.5..3.5)) if i < limited.size
      commenter.merge(stats)
    end
  end

  # Download profile HTML của 1 user và extract stats
  def fetch_user_stats(username, profile_url)
    tmp = Rails.root.join("tmp", "tiktok_stats_#{username}_#{Time.now.to_i}.html")
    success = download_with_curl(profile_url, tmp, referer: "https://www.google.com/")

    unless success && File.exist?(tmp)
      return { followers: nil, following: nil, likes: nil }
    end

    html = File.read(tmp)
    File.delete(tmp) if File.exist?(tmp)

    # Parse stats từ HTML
    extract_stats_from_html(html)
  rescue => e
    Rails.logger.error "fetch_user_stats(#{username}) error: #{e.message}"
    { followers: nil, following: nil, likes: nil }
  end

  def extract_stats_from_html(html)
    # Thử từ JSON script tag (ưu tiên nhất)
    doc = Nokogiri::HTML(html)
    doc.css('script[type="application/json"]').each do |script|
      content = script.content.strip
      next unless content.include?('webapp.user-detail')
      begin
        j = JSON.parse(content)
        user_info = j.dig('__DEFAULT_SCOPE__', 'webapp.user-detail', 'userInfo')
        next unless user_info
        stats = user_info['stats']
        bio   = user_info.dig('user', 'signature').to_s
        return {
          followers: stats['followerCount'].to_i,
          following: stats['followingCount'].to_i,
          likes:     (stats['heartCount'] || stats['heart']).to_i,
          email:     extract_email(bio),
          linktree:  extract_linktree(bio)
        }
      rescue JSON::ParserError
      end
    end

    # Fallback: regex
    followers = html.match(/"followerCount"\s*:\s*(\d+)/)&.[](1).to_i
    following = html.match(/"followingCount"\s*:\s*(\d+)/)&.[](1).to_i
    likes     = html.match(/"heart(?:Count)?"\s*:\s*(\d+)/)&.[](1).to_i
    bio       = html.match(/"signature"\s*:\s*"([^"]+)"/)&.[](1).to_s
    { followers: followers, following: following, likes: likes, email: extract_email(bio), linktree: extract_linktree(bio) }
  end

  # Lấy email đầu tiên tìm thấy trong chuỗi text, nil nếu không có
  def extract_email(text)
    return nil if text.blank?
    text.match(/[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}/)&.[](0)
  end

  # Lấy linktree URL dạng linktr.ee/xxxxx trong bio, nil nếu không có
  def extract_linktree(text)
    return nil if text.blank?
    match = text.match(%r{(?:https?://)?linktr\.ee/([\w.\-]+)})
    return nil unless match
    "https://linktr.ee/#{match[1]}"
  end

  # Danh sách User-Agent để rotate khi bị block
  USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:124.0) Gecko/20100101 Firefox/124.0",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
  ].freeze

  def download_with_curl(url, tmp_file, referer: "https://www.google.com/", accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", retries: 2)
    ua = USER_AGENTS.sample

    # Xây dựng lệnh curl, --noproxy '*' để bypass corporate proxy nếu có
    base_cmd = [
      "curl", "-s", "-L",
      "--noproxy", "*",
      "-A", ua,
      "-H", "Accept: #{accept}",
      "-H", "Accept-Language: en-US,en;q=0.9,ja;q=0.8",
      "-H", "Accept-Encoding: identity",
      "-H", "Referer: #{referer}",
      "-H", "Connection: keep-alive",
      "-H", "Sec-Fetch-Dest: document",
      "-H", "Sec-Fetch-Mode: navigate",
      "-H", "Sec-Fetch-Site: none",
      "-H", "Upgrade-Insecure-Requests: 1",
      "-b", "tt_webid_v2=7379174563279246869; tiktok_webapp_theme=light; tt_chain_token=yPsPGFBjWvHjSM0fL2Miqw==",
      "--max-time", "30",
      "-o", tmp_file.to_s,
      url
    ]

    attempt = 0
    loop do
      _out, stderr, status = Open3.capture3(*base_cmd)

      unless status.success?
        Rails.logger.error "curl failed (attempt #{attempt + 1}): #{stderr}"
        attempt += 1
        break if attempt > retries
        sleep(2 ** attempt)
        next
      end

      # Kiểm tra xem file có bị intercept bởi proxy/firewall không
      if File.exist?(tmp_file)
        size    = File.size(tmp_file)
        preview = File.read(tmp_file, 512).to_s

        if proxy_blocked?(preview, size)
          Rails.logger.warn "Proxy/firewall block detected (attempt #{attempt + 1}), size=#{size}. Preview: #{preview[0..100]}"
          File.delete(tmp_file)
          attempt += 1
          break if attempt > retries
          sleep(3 * attempt)
          next
        end
      end

      return status.success?
    end

    false
  end

  # Phát hiện trang bị chặn bởi corporate proxy, TikTok challenge, hoặc response không hợp lệ
  def proxy_blocked?(preview, size)
    return true if size < 5_000   # WAF tiny pages (<5KB)
    return true if size == 32_768 # TikTok truncated response chính xác 32KB (login required)
    low = preview.downcase
    return true if low.include?('application control violation')
    return true if low.include?('slardarwaf') && !low.include?('__default_scope__')
    return true if low.include?('access denied') && low.include?('policy')
    return true if low.include?('forcepoint') || low.include?('zscaler') || low.include?('bluecoat')
    false
  end

  def extract_username(url)
    url.to_s.match(/@([\w.-]+)/)[1] rescue 'unknown'
  end

  def parse_html(html, url, username)
    doc = Nokogiri::HTML(html)

    doc.css('script[type="application/json"]').each do |script|
      content = script.content.strip
      next unless content.include?('__DEFAULT_SCOPE__') && content.include?('webapp.user-detail')
      begin
        json      = JSON.parse(content)
        user_info = json.dig('__DEFAULT_SCOPE__', 'webapp.user-detail', 'userInfo')
        next unless user_info
        Rails.logger.info "Parsed from application/json script tag"
        return build_result(url, username, user_info['user'], user_info['stats'])
      rescue JSON::ParserError
      end
    end

    doc.css('script').each do |script|
      content = script.content
      next unless content.include?('__UNIVERSAL_DATA_FOR_REHYDRATION__')
      begin
        json_str  = content.match(/__UNIVERSAL_DATA_FOR_REHYDRATION__\s*=\s*(\{.+\})\s*;/m)&.[](1)
        next unless json_str
        json      = JSON.parse(json_str)
        user_info = json.dig('__DEFAULT_SCOPE__', 'webapp.user-detail', 'userInfo')
        next unless user_info
        Rails.logger.info "Parsed from __UNIVERSAL_DATA_FOR_REHYDRATION__"
        return build_result(url, username, user_info['user'], user_info['stats'])
      rescue JSON::ParserError
      end
    end

    doc.css('script').each do |script|
      content = script.content
      next unless content.include?('SIGI_STATE')
      begin
        json_str = content.match(/window\['SIGI_STATE'\]\s*=\s*(\{.+\})\s*;/m)&.[](1) ||
                   content.match(/SIGI_STATE\s*=\s*(\{.+\})\s*;/m)&.[](1)
        next unless json_str
        json = JSON.parse(json_str)
        user = json.dig('UserModule', 'users')&.values&.first
        next unless user
        Rails.logger.info "Parsed from SIGI_STATE"
        return build_result(url, username, user, user['stats'])
      rescue JSON::ParserError
      end
    end

    Rails.logger.info "Trying regex fallback..."
    follower  = html.match(/"followerCount"\s*:\s*(\d+)/)&.[](1).to_i
    following = html.match(/"followingCount"\s*:\s*(\d+)/)&.[](1).to_i
    likes     = html.match(/"heart(?:Count)?"\s*:\s*(\d+)/)&.[](1).to_i
    nickname  = html.match(/"nickname"\s*:\s*"([^"]+)"/)&.[](1)
    avatar    = html.match(/"avatarLarger"\s*:\s*"([^"]+)"/)&.[](1)
    bio       = html.match(/"signature"\s*:\s*"([^"]+)"/)&.[](1)
    videos    = html.match(/"videoCount"\s*:\s*(\d+)/)&.[](1).to_i
    sec_uid   = html.match(/"secUid"\s*:\s*"([^"]+)"/)&.[](1)

    if follower > 0 || following > 0 || likes > 0
      Rails.logger.info "Parsed from regex: followers=#{follower}, following=#{following}, likes=#{likes}"
      return {
        success: true, url: url, username: username,
        sec_uid: sec_uid,
        display_name: nickname, avatar_url: avatar&.gsub('\\u002F', '/'),
        bio: bio, followers: follower, following: following,
        likes: likes, video_count: videos
      }
    end

    # Chẩn đoán nguyên nhân thất bại để trả về error message rõ ràng hơn
    preview_low = html[0..500].downcase
    reason = if html.size < 5_000
      "Trang quá nhỏ (#{html.size} bytes) — có thể bị chặn bởi firewall/proxy"
    elsif html.size == 32_768
      "TikTok trả về trang truncated (32KB) — cần cookie đăng nhập hợp lệ hơn"
    elsif preview_low.include?('application control violation')
      "Bị chặn bởi corporate proxy (Application Control Violation) — kiểm tra VPN"
    elsif preview_low.include?('captcha') || preview_low.include?('challenge')
      "TikTok yêu cầu xác minh captcha — thử lại sau ít phút"
    elsif preview_low.include?('login') && !preview_low.include?('follower')
      "TikTok yêu cầu đăng nhập — cần cập nhật cookie session"
    else
      "Không tìm thấy dữ liệu (#{html.size} bytes). TikTok có thể đã thay đổi cấu trúc HTML"
    end
    Rails.logger.error "Could not parse @#{username}. #{reason}. Preview: #{html[0..200]}"
    { success: false, error: reason }
  end

  def build_result(url, username, user, stats)
    {
      success:      true,
      url:          url,
      username:     username,
      sec_uid:      user['secUid'],
      display_name: user['nickname'],
      avatar_url:   user['avatarLarger'] || user['avatarMedium'],
      bio:          user['signature'],
      followers:    stats&.dig('followerCount').to_i,
      following:    stats&.dig('followingCount').to_i,
      likes:        (stats&.dig('heartCount') || stats&.dig('heart')).to_i,
      video_count:  stats&.dig('videoCount').to_i
    }
  end
end
