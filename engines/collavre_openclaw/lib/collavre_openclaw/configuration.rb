module CollavreOpenclaw
  class Configuration
    # Connection timeout (seconds) - how long to wait for connection
    attr_accessor :open_timeout

    # Read timeout (seconds) - how long to wait for streaming response
    # AI responses can take 60-180+ seconds with reasoning/tools
    attr_accessor :read_timeout

    # Max retries for transient failures
    attr_accessor :max_retries

    def initialize
      @open_timeout = ENV.fetch("OPENCLAW_OPEN_TIMEOUT", 10).to_i
      @read_timeout = ENV.fetch("OPENCLAW_READ_TIMEOUT", 180).to_i  # 3 minutes for AI responses
      @max_retries = ENV.fetch("OPENCLAW_MAX_RETRIES", 2).to_i
    end

    # Legacy accessor for backward compatibility
    def request_timeout
      @read_timeout
    end

    def request_timeout=(value)
      @read_timeout = value
    end
  end
end
