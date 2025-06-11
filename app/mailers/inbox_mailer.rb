class InboxMailer < ApplicationMailer
  def daily_summary
    @user = params[:user]
    @items = params[:items]
    mail to: @user.email, subject: t("inbox_mailer.daily_summary.subject")
  end
end
