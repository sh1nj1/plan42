class UserMailer < ApplicationMailer
  def email_verification(user)
    @user = user
    mail to: user.email, subject: t("user_mailer.email_verification.subject")
  end
end
