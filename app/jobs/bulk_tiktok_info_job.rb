class BulkTiktokInfoJob < ApplicationJob
  queue_as :default

  CACHE_EXPIRY   = 6.hours
  MAX_ENRICH     = 500   # giảm xuống để tránh OOM trên Railway free (512MB RAM)

  def perform(job_id, urls)
    update_progress(job_id, 0, urls.size, "Bắt đầu xử lý #{urls.size} URLs...")

    service        = TiktokHtmlFileService.new
    all_commenters = []   # [{username:, url:, display_name:}]
    url_results    = []

    # ── Phase 1: Thu thập commenters từ top-2 posts của mỗi URL ──────────
    urls.each_with_index do |url, i|
      update_progress(job_id, i + 1, urls.size,
        "[#{i + 1}/#{urls.size}] Đang xử lý: #{url.truncate(60)}")

      begin
        info = service.get_top2_posts_info(url)

        if info[:success]
          raw = info[:commenters_raw] || []
          all_commenters.concat(raw)
          url_results << {
            url:            url,
            username:       info[:username],
            display_name:   info[:display_name],
            videos:         info[:videos] || [],
            commenter_count: raw.size,
            error:          nil
          }
        else
          url_results << { url: url, username: nil, display_name: nil,
                           videos: [], commenter_count: 0, error: info[:error] }
        end
      rescue => e
        Rails.logger.error "[BulkTiktokInfoJob] Error on #{url}: #{e.message}"
        url_results << { url: url, username: nil, display_name: nil,
                         videos: [], commenter_count: 0, error: e.message }
      end
    end

    # ── Phase 2: Dedup ────────────────────────────────────────────────────
    unique_commenters = all_commenters.uniq { |c| c[:username] }
    total_unique      = unique_commenters.size
    update_progress(job_id, urls.size, urls.size,
      "Thu thập xong. #{total_unique} commenters unique. Đang enrich stats...")

    # ── Phase 3: Enrich stats (email, linktree, followers) ───────────────
    to_enrich = unique_commenters.first(MAX_ENRICH)
    enriched  = []

    to_enrich.each_with_index do |commenter, i|
      if (i + 1) % 20 == 0 || i == 0
        update_progress(job_id, urls.size, urls.size,
          "Enrich stats: [#{i + 1}/#{to_enrich.size}] @#{commenter[:username]}")
      end

      begin
        stats = service.send(:fetch_user_stats, commenter[:username], commenter[:url])
        enriched << commenter.merge(stats)
      rescue => e
        Rails.logger.warn "[BulkTiktokInfoJob] enrich error @#{commenter[:username]}: #{e.message}"
        enriched << commenter.merge(followers: nil, following: nil, likes: nil, email: nil, linktree: nil)
      end
      # Delay ngẫu nhiên để tránh TikTok rate-limit
      sleep(rand(1.5..3.5)) if i < to_enrich.size
    end

    # Append any commenters beyond MAX_ENRICH without stats
    if unique_commenters.size > MAX_ENRICH
      unique_commenters[MAX_ENRICH..].each do |c|
        enriched << c.merge(followers: nil, following: nil, likes: nil, email: nil, linktree: nil)
      end
    end

    # Sort: có email trước → chỉ linktree → còn lại
    sorted = enriched.sort_by do |c|
      if c[:email].present?    then 0
      elsif c[:linktree].present? then 1
      else 2
      end
    end

    stats_summary = {
      total_urls:       urls.size,
      success_urls:     url_results.count { |r| r[:error].nil? },
      total_commenters: total_unique,
      with_email:       sorted.count { |c| c[:email].present? },
      with_linktree:    sorted.count { |c| c[:linktree].present? },
      enriched_count:   to_enrich.size
    }

    # ── Phase 4: Lưu kết quả ─────────────────────────────────────────────
    Rails.cache.write(
      "bulk_tiktok_result:#{job_id}",
      { url_results: url_results, commenters: sorted, stats: stats_summary }.to_json,
      expires_in: CACHE_EXPIRY,
      raw: true
    )

    update_progress(job_id, urls.size, urls.size,
      "✅ Hoàn thành! #{total_unique} commenters, #{stats_summary[:with_email]} có email, #{stats_summary[:with_linktree]} có linktree.",
      status: "done")

    Rails.logger.info "[BulkTiktokInfoJob #{job_id}] Finished. #{stats_summary.inspect}"
  rescue => e
    Rails.logger.error "[BulkTiktokInfoJob #{job_id}] Fatal: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    update_progress(job_id, 0, 1, "❌ Lỗi: #{e.message}", status: "failed")
  end

  private

  def update_progress(job_id, current, total, message, status: "running")
    Rails.cache.write(
      "bulk_tiktok_progress:#{job_id}",
      { status: status, current: current, total: total, message: message }.to_json,
      expires_in: CACHE_EXPIRY,
      raw: true
    )
  end
end
