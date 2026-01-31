module CollavreOpenclaw
  class Configuration
    # Default webhook secret for verifying inbound requests
    # Each OpenclawAccount can override this
    attr_accessor :default_webhook_secret

    # Default timeout for outbound requests (seconds)
    attr_accessor :request_timeout

    def initialize
      @default_webhook_secret = ENV.fetch("OPENCLAW_WEBHOOK_SECRET", "")
      @request_timeout = ENV.fetch("OPENCLAW_REQUEST_TIMEOUT", 30).to_i
    end
  end
end
