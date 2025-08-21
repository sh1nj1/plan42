class ApplicationMailer < ActionMailer::Base
  default from: "soonoh.jung@vrerv.com"
  layout "mailer"

  def mail(headers = {}, &block)
    recipients = Array(headers[:to]).compact - [ User::ANONYMOUS_EMAIL ]
    return if recipients.empty?
    super(headers.merge(to: recipients), &block)
  end

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
