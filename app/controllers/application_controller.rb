class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  before_action :require_login

  helper_method :logged_in?, :current_user_email, :current_user

  private

  def current_user
    @current_user ||= User.find_by(id: session[:user_id]) if session[:user_id]
  end

  def logged_in?
    current_user.present?
  end

  def current_user_email
    current_user&.email
  end

  def require_login
    unless logged_in?
      redirect_to root_path, alert: "Vui lòng đăng nhập để tiếp tục"
    end
  end
end
