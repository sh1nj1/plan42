class ExampleDomainInterceptor
  EXCLUDED_DOMAIN = "example.com".freeze

  def self.delivering_email(message)
    [ :to, :cc, :bcc ].each do |field|
      emails = Array(message.public_send(field))
      filtered = emails.reject { |email| email.to_s.downcase.end_with?("@#{EXCLUDED_DOMAIN}") }
      message.public_send("#{field}=", filtered.presence)
    end

    if message.to.blank? && message.cc.blank? && message.bcc.blank?
      message.perform_deliveries = false
    end
  end
end

ActionMailer::Base.register_interceptor(ExampleDomainInterceptor)
