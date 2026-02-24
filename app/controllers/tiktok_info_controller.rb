class TiktokInfoController < ApplicationController
  def index
  end

  def fetch
    tiktok_url = params[:tiktok_url].to_s.strip
    if tiktok_url.blank?
      flash[:alert] = "Vui lòng nhập URL TikTok"
      redirect_to tiktok_info_path and return
    end
    service = TiktokHtmlFileService.new
    @result = service.get_info(tiktok_url)
    if @result[:success]
      render :result
    else
      flash[:alert] = "Không thể lấy thông tin: #{@result[:error]}"
      redirect_to tiktok_info_path
    end
  end
end
