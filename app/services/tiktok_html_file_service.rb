class TiktokHtmlFileService
  require 'nokogiri'
  require 'json'
  require 'open3'

  USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

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

    # Xóa file tạm sau khi parse xong
    File.delete(tmp_file) if File.exist?(tmp_file)
    Rails.logger.info "Temp file deleted."

    result
  rescue => e
    File.delete(tmp_file) if tmp_file && File.exist?(tmp_file)
    Rails.logger.error "Error: #{e.message}"
    { success: false, error: e.message }
  end

  private

  def download_with_curl(url, tmp_file)
    # Dùng system curl với đầy đủ headers để bypass TikTok WAF
    cmd = [
      "curl", "-s", "-L",
      "-A", USER_AGENT,
      "-H", "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      "-H", "Accept-Language: en-US,en;q=0.9",
      "-H", "Accept-Encoding: identity",
      "-H", "Referer: https://www.google.com/",
      "-H", "Connection: keep-alive",
      "-b", "tt_webid_v2=123456789; tiktok_webapp_theme=light",
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

    # Thử parse từ __UNIVERSAL_DATA_FOR_REHYDRATION__
    doc.css('script').each do |script|
      content = script.content
      next unless content.include?('__UNIVERSAL_DATA_FOR_REHYDRATION__')
      begin
        json_str = content.match(/__UNIVERSAL_DATA_FOR_REHYDRATION__\s*=\s*(\{.+\})\s*;/m)&.[](1)
        next unless json_str
        json = JSON.parse(json_str)
        user_info = json.dig('__DEFAULT_SCOPE__', 'webapp.user-detail', 'userInfo')
        next unless user_info
        Rails.logger.info "✅ Parsed from __UNIVERSAL_DATA_FOR_REHYDRATION__"
        return build_result(url, username, user_info['user'], user_info['stats'])
      rescue JSON::ParserError
      end
    end

    # Thử parse từ SIGI_STATE
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
        Rails.logger.info "✅ Parsed from SIGI_STATE"
        return build_result(url, username, user, user['stats'])
      rescue JSON::ParserError
      end
    end

    # Fallback: regex trực tiếp trên raw HTML
    Rails.logger.info "Trying regex fallback..."
    follower  = html.match(/"followerCount"\s*:\s*(\d+)/)&.[](1).to_i
    following = html.match(/"followingCount"\s*:\s*(\d+)/)&.[](1).to_i
    likes     = html.match(/"heart(?:Count)?"\s*:\s*(\d+)/)&.[](1).to_i
    nickname  = html.match(/"nickname"\s*:\s*"([^"]+)"/)&.[](1)
    avatar    = html.match(/"avatarLarger"\s*:\s*"([^"]+)"/)&.[](1)
    bio       = html.match(/"signature"\s*:\s*"([^"]+)"/)&.[](1)
    videos    = html.match(/"videoCount"\s*:\s*(\d+)/)&.[](1).to_i

    if follower > 0 || following > 0 || likes > 0
      Rails.logger.info "✅ Parsed from regex: followers=#{follower}, following=#{following}, likes=#{likes}"
      return {
        success: true,
        url: url,
        username: username,
        display_name: nickname,
        avatar_url: avatar&.gsub('\\u002F', '/'),
        bio: bio,
        followers: follower,
        following: following,
        likes: likes,
        video_count: videos
      }
    end

    Rails.logger.error "❌ Could not parse data. HTML preview: #{html[0..300]}"
    { success: false, error: "Không tìm thấy dữ liệu. TikTok có thể đang chặn request." }
  end

  def build_result(url, username, user, stats)
    {
      success: true,
      url: url,
      username: username,
      display_name: user['nickname'],
      avatar_url: user['avatarLarger'] || user['avatarMedium'],
      bio: user['signature'],
      followers: stats&.dig('followerCount').to_i,
      following: stats&.dig('followingCount').to_i,
      likes: (stats&.dig('heartCount') || stats&.dig('heart')).to_i,
      video_count: stats&.dig('videoCount').to_i
    }
  end
end
