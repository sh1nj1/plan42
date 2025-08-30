class InboxMailer < ApplicationMailer
  def daily_summary
    @user = params[:user]
    @items = params[:items]
    locale = @user.locale || "en-US"
    email = I18n.with_locale(locale.to_s.split("-").first) do
      mail to: @user.email, subject: t("inbox_mailer.daily_summary.subject")
    end
    Email.create!(
      user: @user,
      email: @user.email,
      subject: email.subject,
      body: extract_body(email),
      event: :inbox_summary
    )
  end
end
