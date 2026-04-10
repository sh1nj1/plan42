module CollavreOpenclaw
  class Configuration
    # Connection timeout (seconds) - how long to wait for connection
    attr_accessor :open_timeout

    # Read timeout (seconds) - how long to wait for streaming response
    # AI responses can take 60-180+ seconds with reasoning/tools
    attr_accessor :read_timeout

    # Max retries for transient failures
    attr_accessor :max_retries

    # WebSocket idle timeout (seconds) - disconnect after inactivity
    attr_accessor :ws_idle_timeout

    # WebSocket max reconnect attempts before giving up
    attr_accessor :ws_reconnect_max

    # WebSocket reconnect base delay (seconds) - exponential backoff base
    attr_accessor :ws_reconnect_base_delay

    # WebSocket connect timeout (seconds)
    attr_accessor :ws_connect_timeout

    # Transport mode: "auto" (WebSocket first, HTTP fallback), "http" (HTTP only)
    attr_accessor :transport

    def initialize
      @open_timeout = ENV.fetch("OPENCLAW_OPEN_TIMEOUT", 10).to_i
      @read_timeout = begin
        Collavre::SystemSetting.llm_request_timeout_seconds
      rescue StandardError
        1800
      end
      @max_retries = ENV.fetch("OPENCLAW_MAX_RETRIES", 2).to_i
      @ws_idle_timeout = ENV.fetch("OPENCLAW_WS_IDLE_TIMEOUT", 1800).to_i     # 30 minutes
      @ws_reconnect_max = ENV.fetch("OPENCLAW_WS_RECONNECT_MAX", 10).to_i
      @ws_reconnect_base_delay = ENV.fetch("OPENCLAW_WS_RECONNECT_BASE", 1).to_f
      @ws_connect_timeout = ENV.fetch("OPENCLAW_WS_CONNECT_TIMEOUT", 10).to_i
      @transport = ENV.fetch("OPENCLAW_TRANSPORT", "auto")
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
