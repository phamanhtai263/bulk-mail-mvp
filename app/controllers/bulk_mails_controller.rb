class BulkMailsController < ApplicationController
  def index
    # Hiển thị danh sách email đã gửi (tùy chọn)
    redirect_to new_bulk_mail_path
  end

  def new
    # Form tạo email hàng loạt
  end

  def create
    # Xử lý gửi email hàng loạt
    recipients_text = params[:recipients]
    email_content = params[:email_content]
    var_1 = params[:var_1]
    var_2 = params[:var_2]
    var_3 = params[:var_3]
    var_4 = params[:var_4]
    var_5 = params[:var_5]

    # Parse danh sách người nhận
    recipients = parse_recipients(recipients_text)

    if recipients.empty?
      flash[:alert] = "Vui lòng nhập danh sách người nhận hợp lệ"
      render :new, status: :unprocessable_entity
      return
    end

    if email_content.blank?
      flash[:alert] = "Vui lòng nhập nội dung email"
      render :new, status: :unprocessable_entity
      return
    end

    # Gửi email cho từng người nhận
    success_count = 0
    recipients.each do |recipient|
      personalized_content = personalize_content(
        email_content,
        recipient[:email],
        recipient[:full_name],
        var_1, var_2, var_3, var_4, var_5
      )

      # TODO: Tích hợp với email service thực tế (ActionMailer, SendGrid, etc.)
      # Hiện tại chỉ log ra console
      Rails.logger.info "Sending to: #{recipient[:email]} (#{recipient[:full_name]})"
      Rails.logger.info "Content: #{personalized_content}"
      
      success_count += 1
    end

    redirect_to menu_path, notice: "Đã gửi thành công #{success_count} email!"
  end

  private

  def parse_recipients(text)
    return [] if text.blank?

    recipients = []
    text.split("\n").each do |line|
      line = line.strip
      next if line.empty?

      # Format: email@example.com, Full Name
      parts = line.split(",", 2)
      if parts.length == 2
        email = parts[0].strip
        full_name = parts[1].strip
        recipients << { email: email, full_name: full_name } if email.present?
      end
    end
    recipients
  end

  def personalize_content(content, email, full_name, var_1, var_2, var_3, var_4, var_5)
    content
      .gsub("%<email>", email)
      .gsub("%<full_name>", full_name)
      .gsub("%<var_1>", var_1.to_s)
      .gsub("%<var_2>", var_2.to_s)
      .gsub("%<var_3>", var_3.to_s)
      .gsub("%<var_4>", var_4.to_s)
      .gsub("%<var_5>", var_5.to_s)
  end
end
