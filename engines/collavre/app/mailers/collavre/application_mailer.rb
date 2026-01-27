module Collavre
  class ApplicationMailer < ActionMailer::Base
    default from: ENV.fetch("DEFAULT_MAILER_FROM", "no-reply@example.com")
    layout "mailer"

    private

    def extract_body(email)
      if email.multipart?
        part = email.text_part || email.html_part
        part&.body&.decoded.to_s
      else
        email.body.decoded
      end
    end
  end
end
