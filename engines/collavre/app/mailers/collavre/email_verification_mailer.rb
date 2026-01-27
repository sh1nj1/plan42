module Collavre
  class EmailVerificationMailer < ApplicationMailer
    helper Collavre::Engine.routes.url_helpers

    def verify(user)
      @user = user
      mail to: user.email, subject: I18n.t("collavre.user_mailer.email_verification.subject")
    end

    private

    def verify_url(token:)
      collavre_engine_url_helpers.email_verification_url(token: token)
    end

    def collavre_engine_url_helpers
      Collavre::Engine.routes.url_helpers
    end
  end
end
