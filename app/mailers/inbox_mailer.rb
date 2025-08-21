class InboxMailer < ApplicationMailer
  def daily_summary
    @user = params[:user]
    @items = params[:items]
    locale = @user.locale.presence || I18n.default_locale.to_s
    email = I18n.with_locale(locale) do
      mail to: @user.email, subject: t("inbox_mailer.daily_summary.subject")
    end
    return unless email
    Email.create!(
      user: @user,
      email: @user.email,
      subject: email.subject,
      body: extract_body(email),
      event: :inbox_summary
    )
  end
end
