class AdminController < ApplicationController
  before_action :require_admin

  def index
    @railway = RailwayService.new
    @service_status = @railway.status
    @deploy_hook_url = ENV.fetch("RAILWAY_DEPLOY_HOOK_URL", nil)
  end

  def suspend
    railway = RailwayService.new
    result  = railway.suspend

    if result[:success]
      flash[:notice] = "✅ Đã gửi lệnh Suspend thành công. Server sẽ tắt trong vài giây."
    else
      flash[:alert] = "❌ Suspend thất bại: #{result[:error]}"
    end

    redirect_to admin_path
  end

  private

  def require_admin
    admin_emails = ENV.fetch("ADMIN_EMAILS", "").split(",").map(&:strip)
    unless admin_emails.include?(current_user_email.to_s)
      flash[:alert] = "Bạn không có quyền truy cập trang này."
      redirect_to menu_path
    end
  end
end
