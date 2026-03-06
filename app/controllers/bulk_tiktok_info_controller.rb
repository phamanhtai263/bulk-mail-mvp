class BulkTiktokInfoController < ApplicationController
  def index
  end

  def submit
    raw = params[:tiktok_urls].to_s
    urls = raw.lines.map(&:strip).select { |l| l.match?(/tiktok\.com\/@[\w.\-]+/i) }.uniq

    if urls.empty?
      flash[:alert] = "Vui lòng nhập ít nhất 1 URL TikTok hợp lệ."
      redirect_to bulk_tiktok_info_path and return
    end

    if urls.size > 100
      flash[:alert] = "Tối đa 100 URLs mỗi lần để tránh OOM và TikTok rate limit. Hãy chia thành nhiều batch nhỏ."
      redirect_to bulk_tiktok_info_path and return
    end

    job_id = SecureRandom.hex(16)

    # Khởi tạo trạng thái pending
    Rails.cache.write(
      "bulk_tiktok_progress:#{job_id}",
      { status: "pending", current: 0, total: urls.size, message: "Đang chờ worker khởi động..." }.to_json,
      expires_in: 6.hours,
      raw: true
    )

    BulkTiktokInfoJob.perform_later(job_id, urls)

    redirect_to bulk_tiktok_info_status_path(job_id: job_id)
  end

  def status
    @job_id = params[:job_id]
    respond_to do |format|
      format.html
      format.json do
        raw = Rails.cache.read("bulk_tiktok_progress:#{@job_id}", raw: true)
        if raw
          render json: JSON.parse(raw)
        else
          render json: { status: "not_found", message: "Không tìm thấy job." }, status: :not_found
        end
      end
    end
  end

  def result
    @job_id = params[:job_id]
    raw     = Rails.cache.read("bulk_tiktok_result:#{@job_id}", raw: true)

    unless raw
      respond_to do |format|
        format.html do
          flash[:alert] = "Kết quả không tìm thấy hoặc đã hết hạn (6 giờ)."
          redirect_to bulk_tiktok_info_path
        end
        format.json { render json: { error: "Kết quả không tìm thấy hoặc đã hết hạn." }, status: :not_found }
      end
      return
    end

    data             = JSON.parse(raw, symbolize_names: true)
    @commenters      = data[:commenters] || []
    @url_results     = data[:url_results] || []
    @stats           = data[:stats] || {}

    respond_to do |format|
      format.html
      format.json { render json: { commenters: @commenters, url_results: @url_results, stats: @stats } }
    end
  end
end
