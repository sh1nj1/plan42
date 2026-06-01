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
      @open_timeout            = fetch_int(:openclaw_open_timeout, 10)
      @read_timeout = begin
        Collavre::SystemSetting.llm_request_timeout_seconds
      rescue StandardError
        1800
      end
      @max_retries             = fetch_int(:openclaw_max_retries, 2)
      @ws_idle_timeout         = fetch_int(:openclaw_ws_idle_timeout, 1800)  # 30 minutes
      @ws_reconnect_max        = fetch_int(:openclaw_ws_reconnect_max, 10)
      @ws_reconnect_base_delay = fetch_float(:openclaw_ws_reconnect_base, 1)
      @ws_connect_timeout      = fetch_int(:openclaw_ws_connect_timeout, 10)
      @transport               = fetch_string(:openclaw_transport, "auto")
    end

    # Legacy accessor for backward compatibility
    def request_timeout
      @read_timeout
    end

    def request_timeout=(value)
      @read_timeout = value
    end

    private

    def fetch_string(key, default)
      raw = Collavre::IntegrationSettings.fetch(key)
      raw.presence || default
    end

    def fetch_int(key, default)
      raw = Collavre::IntegrationSettings.fetch(key)
      raw.present? ? raw.to_i : default
    end

    def fetch_float(key, default)
      raw = Collavre::IntegrationSettings.fetch(key)
      raw.present? ? raw.to_f : default
    end
  end
end
