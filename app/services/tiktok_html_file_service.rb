class TiktokHtmlFileService
  require 'nokogiri'
  require 'json'
  require 'open3'

  USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  COMMENT_COUNT_PER_PAGE = 20
  MAX_COMMENT_PAGES = 10   # tối đa 200 comments
  MAX_STATS_FETCH    = 30  # tối đa fetch stats cho 30 commenters để tránh timeout

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

    latest_post = get_latest_post_with_commenters(username)
    result.merge(latest_post)
  rescue => e
    File.delete(tmp_file) if tmp_file && File.exist?(tmp_file)
    Rails.logger.error "TiktokHtmlFileService Error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
    { success: false, error: e.message }
  end

  private

  def get_latest_post_with_commenters(username)
    embed_file = Rails.root.join("tmp", "tiktok_embed_#{username}_#{Time.now.to_i}.html")
    embed_url  = "https://www.tiktok.com/embed/@#{username}"

    Rails.logger.info "=== Downloading embed page for: #{username} ==="
    success = download_with_curl(embed_url, embed_file, referer: "https://www.google.com/")

    unless success && File.exist?(embed_file)
      return { latest_post_url: nil, commenters: [] }
    end

    embed_html = File.read(embed_file)
    File.delete(embed_file) if File.exist?(embed_file)
    Rails.logger.info "Embed HTML: #{embed_html.size} bytes, deleted."

    escaped  = Regexp.escape(username)
    video_ids = embed_html.scan(%r{tiktok\.com/@#{escaped}/video/(\d+)}).flatten.uniq

    if video_ids.empty?
      Rails.logger.warn "No video IDs found in embed page"
      return { latest_post_url: nil, commenters: [] }
    end

    latest_id  = video_ids.max_by(&:to_i)
    latest_url = "https://www.tiktok.com/@#{username}/video/#{latest_id}"
    Rails.logger.info "Latest video ID: #{latest_id}"

    # Bước 1: Lấy list commenters (username + url)
    commenters = fetch_all_commenters(latest_id, username)

    # Bước 2: Fetch stats (followers/following/likes) cho từng commenter
    commenters = enrich_with_stats(commenters)

    { latest_post_url: latest_url, commenters: commenters }
  rescue => e
    Rails.logger.error "get_latest_post_with_commenters error: #{e.message}"
    { latest_post_url: nil, commenters: [] }
  end

  # Trả về [{username:, url:, display_name:}]
  def fetch_all_commenters(video_id, username)
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
      break unless has_more && comments.any? && page < MAX_COMMENT_PAGES
      cursor = j["cursor"].to_i
    end

    Rails.logger.info "Total commenters: #{all.size}"
    # Dedup by username
    all.uniq { |c| c[:username] }
  end

  # Fetch followers/following/likes mỗi commenter bằng cách download profile page
  def enrich_with_stats(commenters)
    limited = commenters.first(MAX_STATS_FETCH)
    Rails.logger.info "Fetching stats for #{limited.size} commenters..."

    limited.map.with_index(1) do |commenter, i|
      Rails.logger.info "  [#{i}/#{limited.size}] @#{commenter[:username]}"
      stats = fetch_user_stats(commenter[:username], commenter[:url])
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
        stats = j.dig('__DEFAULT_SCOPE__', 'webapp.user-detail', 'userInfo', 'stats')
        next unless stats
        return {
          followers: stats['followerCount'].to_i,
          following: stats['followingCount'].to_i,
          likes:     (stats['heartCount'] || stats['heart']).to_i
        }
      rescue JSON::ParserError
      end
    end

    # Fallback: regex
    followers = html.match(/"followerCount"\s*:\s*(\d+)/)&.[](1).to_i
    following = html.match(/"followingCount"\s*:\s*(\d+)/)&.[](1).to_i
    likes     = html.match(/"heart(?:Count)?"\s*:\s*(\d+)/)&.[](1).to_i
    { followers: followers, following: following, likes: likes }
  end

  def download_with_curl(url, tmp_file, referer: "https://www.google.com/", accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
    cmd = [
      "curl", "-s", "-L", "-k",
      "-A", USER_AGENT,
      "-H", "Accept: #{accept}",
      "-H", "Accept-Language: en-US,en;q=0.9",
      "-H", "Accept-Encoding: identity",
      "-H", "Referer: #{referer}",
      "-H", "Connection: keep-alive",
      "-b", "tt_webid_v2=7379174563279246869; tiktok_webapp_theme=light",
      "--max-time", "30",
      "-o", tmp_file.to_s,
      url
    ]
    _out, stderr, status = Open3.capture3(*cmd)
    if status.success?
      true
    else
      Rails.logger.error "curl failed: #{stderr}"
      false
    end
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

    if follower > 0 || following > 0 || likes > 0
      Rails.logger.info "Parsed from regex: followers=#{follower}, following=#{following}, likes=#{likes}"
      return {
        success: true, url: url, username: username,
        display_name: nickname, avatar_url: avatar&.gsub('\\u002F', '/'),
        bio: bio, followers: follower, following: following,
        likes: likes, video_count: videos
      }
    end

    Rails.logger.error "Could not parse. Preview: #{html[0..200]}"
    { success: false, error: "Không tìm thấy dữ liệu. TikTok có thể đang chặn request." }
  end

  def build_result(url, username, user, stats)
    {
      success:      true,
      url:          url,
      username:     username,
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
