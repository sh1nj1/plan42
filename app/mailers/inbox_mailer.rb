class InboxMailer < ApplicationMailer
  def daily_summary
    @user = params[:user]
    @items = params[:items]
    email = mail to: @user.email, subject: t("inbox_mailer.daily_summary.subject")
    Email.create!(
      user: @user,
      email: @user.email,
      subject: email.subject,
      body: email.body.raw_source,
      event: :inbox_summary
    )
  end
end
