class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("DEFAULT_MAILER_FROM", "no-reply@example.com")
  layout "mailer"

  private

  # Returns the decoded body of the email. For multipart emails, prefer the text
  # part when available, falling back to the HTML part.
  def extract_body(email)
    if email.multipart?
      part = email.text_part || email.html_part
      part&.body&.decoded.to_s
    else
      email.body.decoded
    end
  end
end
