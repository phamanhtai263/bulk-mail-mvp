class FetchCommenterStatsJob < ApplicationJob
  queue_as :default

  # pending_commenters: [{username:, url:, index:}] (index là vị trí 0-based trong mảng commenters)
  # cache_key: unique key để lưu kết quả vào Rails.cache
  def perform(pending_commenters, cache_key)
    service = TiktokHtmlFileService.new
    results = {}  # { index => { followers:, following:, likes: } }

    pending_commenters.each_with_index do |commenter, i|
      username = commenter["username"] || commenter[:username]
      url      = commenter["url"]      || commenter[:url]
      idx      = commenter["index"]    || commenter[:index]

      Rails.logger.info "[FetchCommenterStatsJob] #{i + 1}/#{pending_commenters.size} @#{username}"
      stats = service.send(:fetch_user_stats, username, url)
      results[idx.to_s] = {
        followers: stats[:followers],
        following: stats[:following],
        likes:     stats[:likes]
      }
    end

    # Lưu kết quả vào cache 1 giờ
    Rails.cache.write(cache_key, { done: true, stats: results }, expires_in: 1.hour)
    Rails.logger.info "[FetchCommenterStatsJob] Done. Stored #{results.size} stats at #{cache_key}"
  end
end
