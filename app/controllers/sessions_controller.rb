class SessionsController < ApplicationController
  skip_before_action :require_login, only: [:new, :create]

  def new
    # Trang login
    redirect_to menu_path if logged_in?
  end

  def create
    # Xử lý đăng nhập với User model
    user = User.authenticate(params[:email], params[:password])

    if user
      session[:user_id] = user.id
      session[:user_email] = user.email
      redirect_to menu_path, notice: "Đăng nhập thành công!"
    else
      flash.now[:alert] = "Email hoặc mật khẩu không đúng"
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    # Đăng xuất
    session[:user_id] = nil
    session[:user_email] = nil
    redirect_to root_path, notice: "Đã đăng xuất"
  end
end
