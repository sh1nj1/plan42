require "faraday"
require "json"

module CollavreOpenclaw
  class OpenclawAdapter
    # Adapter for OpenClaw AI Gateway
    #
    # Supports two transport modes:
    # 1. WebSocket (primary) - via faye-websocket + EventMachine
    # 2. HTTP (fallback) - via Faraday POST /v1/chat/completions
    #
    # Session mapping:
    #   Collavre Topic → OpenClaw Session (1:1)
    #   Same Topic, multiple users → shared context
    #   Different Topics → isolated sessions

    def initialize(user:, system_prompt:, context: {})
      @user = user
      @system_prompt = system_prompt
      @context = context
    end

    def chat(messages, &block)
      unless @user&.gateway_url.present?
        Rails.logger.error("[CollavreOpenclaw] No Gateway URL configured for user #{@user&.id}")
        yield "Error: OpenClaw Gateway URL not configured" if block_given?
        return nil
      end

      unless @user&.llm_api_key.present?
        Rails.logger.error("[CollavreOpenclaw] No API key configured for user #{@user&.id}")
        yield "Error: OpenClaw API key not configured or decryption failed. " \
              "Please re-enter the API key in AI agent settings." if block_given?
        return nil
      end

      # Try WebSocket first, fall back to HTTP
      if websocket_available?
        chat_via_websocket(messages, &block)
      else
        chat_via_http(messages, &block)
      end
    end

    # Get the callback URL for this user (kept for backward compatibility)
    def callback_url
      return nil unless @user

      host_options = default_url_options
      return nil if host_options[:host].blank?

      CollavreOpenclaw::Engine.routes.url_helpers.callback_url(
        user_id: @user.id,
        **host_options
      )
    rescue StandardError => e
      Rails.logger.warn("[CollavreOpenclaw] Failed to generate callback URL: #{e.message}")
      nil
    end

    # Get the stable session key for this context
    def session_key
      @session_key ||= build_session_key
    end

    private

    # ─────────────────────────────────────────────
    # WebSocket transport
    # ─────────────────────────────────────────────

    def websocket_available?
      # Resolve via the module namespace to trigger Rails autoloading.
      # `defined?` alone does not autoload in dev/test (lazy mode).
      CollavreOpenclaw::ConnectionManager &&
        CollavreOpenclaw::WebsocketClient &&
        true
    rescue NameError
      false
    end

    def chat_via_websocket(messages, &block)
      response_content = +""

      begin
        client = ConnectionManager.instance.connection_for(@user)
        message_text = format_message_for_ws(messages)

        Rails.logger.info("[CollavreOpenclaw] Sending via WebSocket (session: #{session_key})")

        client.chat_send(
          session_key: session_key,
          message: message_text
        ) do |event|
          case event[:state]
          when "delta"
            if event[:text].present?
              response_content << event[:text]
              yield event[:text] if block_given?
            end
          when "final"
            # If no deltas were streamed, final contains the full text
            if response_content.blank? && event[:text].present?
              response_content << event[:text]
              yield event[:text] if block_given?
            end
          when "error"
            error_msg = event[:text] || "Unknown error"
            yield "OpenClaw Error: #{error_msg}" if block_given?
          when "aborted"
            # User or system aborted
          end
        end

        response_content.presence
      rescue CollavreOpenclaw::ConnectionError,
             CollavreOpenclaw::TimeoutError => e
        Rails.logger.warn("[CollavreOpenclaw] WebSocket failed, falling back to HTTP: #{e.message}")
        chat_via_http(messages, &block)
      rescue CollavreOpenclaw::ChatError, CollavreOpenclaw::RpcError => e
        Rails.logger.error("[CollavreOpenclaw] WebSocket chat error: #{e.message}")
        error_msg = "OpenClaw Error: #{e.message}"
        yield error_msg if block_given?
        nil
      rescue StandardError => e
        Rails.logger.error("[CollavreOpenclaw] WebSocket unexpected error: #{e.message}\n" \
                           "#{e.backtrace.first(5).join("\n")}")
        Rails.logger.info("[CollavreOpenclaw] Falling back to HTTP")
        chat_via_http(messages, &block)
      end
    end

    # Format messages for WebSocket chat.send (single message string).
    # Gateway manages session history, so we only send the latest user message
    # with optional context prefix on the FIRST message only.
    def format_message_for_ws(messages)
      formatted = Array(messages)

      # Extract the last user message
      last_user = formatted.reverse.find do |m|
        role = m[:role] || m["role"]
        role.to_s == "user"
      end

      return "" unless last_user

      text = extract_message_text(last_user)

      # Only prepend creative context on the first message in a session.
      # If there are prior assistant replies, the Gateway already has context.
      if first_message_in_session?(formatted)
        context_prefix = build_context_prefix(formatted)
        if context_prefix.present?
          return "#{context_prefix}\n\n#{text}"
        end
      end

      text.to_s
    end

    # Returns true when this looks like the first exchange in a session
    # (no prior assistant messages in the conversation history).
    def first_message_in_session?(messages)
      messages.none? do |m|
        role = m[:role] || m["role"]
        role.to_s == "assistant"
      end
    end

    # Build a context prefix from system/context messages if present.
    # This includes creative tree markdown and other context that the Gateway
    # wouldn't have from its own agent config.
    def build_context_prefix(messages)
      # Find the first "user" message that looks like creative context
      # (typically starts with "Creative:\n")
      context_msg = messages.find do |m|
        role = m[:role] || m["role"]
        text = extract_message_text(m)
        role.to_s == "user" && text&.start_with?("Creative:")
      end

      return nil unless context_msg

      extract_message_text(context_msg)
    end

    def extract_message_text(message)
      parts = message[:parts] || message["parts"]
      if parts
        Array(parts).filter_map { |p| p[:text] || p["text"] }.join("\n")
      else
        message[:text] || message["text"] || message[:content] || message["content"]
      end
    end

    # ─────────────────────────────────────────────
    # HTTP transport (fallback)
    # ─────────────────────────────────────────────

    def chat_via_http(messages, &block)
      response_content = +""

      begin
        payload = build_payload(messages)

        Rails.logger.info("[CollavreOpenclaw] Sending via HTTP to #{api_endpoint} (session: #{session_key})")

        stream_response(payload) do |chunk|
          response_content << chunk
          yield chunk if block_given?
        end

        response_content.presence
      rescue StandardError => e
        Rails.logger.error("[CollavreOpenclaw] HTTP chat error: #{e.message}\n" \
                           "#{e.backtrace.first(5).join("\n")}")
        error_msg = "OpenClaw Error: #{e.message}"
        yield error_msg if block_given?
        nil
      end
    end

    def api_endpoint
      uri = URI.parse(@user.gateway_url)
      uri.path = "/v1/chat/completions"
      uri.to_s
    end

    # ─────────────────────────────────────────────
    # Session key
    # ─────────────────────────────────────────────

    # Build stable session key based on Topic (not nonce)
    # Same Topic = Same Session = Shared context between users
    # Format: agent:<agent_id>:collavre:<user_id>:creative:<id>:topic:<id>
    def build_session_key
      creative_id = extract_id(@context, :creative) || @context[:creative_id]
      topic_id = @context[:thread_id] || @context[:topic_id]
      agent_id = extract_agent_id_from_email || "main"

      parts = [ "agent", agent_id, "collavre", @user.id ]
      parts << "creative:#{creative_id}" if creative_id
      parts << "topic:#{topic_id}" if topic_id

      parts.join(":")
    end

    # ─────────────────────────────────────────────
    # HTTP payload building
    # ─────────────────────────────────────────────

    def build_payload(messages)
      agent_id = extract_agent_id_from_email
      model_value = agent_id.present? ? "openclaw:#{agent_id}" : "openclaw"

      payload = {
        model: model_value,
        messages: format_messages(messages),
        stream: true
      }

      if @system_prompt.present?
        payload[:messages].unshift({ role: "system", content: @system_prompt })
      end

      payload[:user] = build_user_context
      payload
    end

    def build_user_context
      context_data = {}

      creative_id = extract_id(@context, :creative) || @context[:creative_id]
      comment_id = extract_id(@context, :comment) || @context[:comment_id]
      topic_id = @context[:thread_id] || @context[:topic_id]

      callback = callback_url
      if callback.present? && creative_id.present?
        pending = PendingCallback.create_for_request(
          user: @user,
          creative_id: creative_id,
          comment_id: comment_id,
          thread_id: topic_id,
          context: @context.slice(:extra_data).to_h
        )

        context_data[:callback_url] = callback
        context_data[:callback_nonce] = pending.nonce
        context_data[:creative_id] = creative_id
        context_data[:comment_id] = comment_id if comment_id
        context_data[:topic_id] = topic_id if topic_id

        Rails.logger.info("[CollavreOpenclaw] Created pending callback nonce: #{pending.nonce[0..8]}...")
      end

      if context_data.any?
        "collavre:#{JSON.generate(context_data)}"
      else
        "collavre:#{@user.id}"
      end
    end

    def format_messages(messages)
      Array(messages).map do |msg|
        role = msg[:role] || msg["role"]
        content = extract_message_text(msg)

        sender_name = msg[:sender_name] || msg["sender_name"]
        if sender_name.present? && normalize_role(role) == "user"
          content = "[#{sender_name}]: #{content}"
        end

        { role: normalize_role(role), content: content.to_s }
      end
    end

    def normalize_role(role)
      case role.to_s
      when "model", "assistant" then "assistant"
      when "system" then "system"
      else "user"
      end
    end

    # ─────────────────────────────────────────────
    # HTTP streaming
    # ─────────────────────────────────────────────

    def build_headers
      headers = {
        "Content-Type" => "application/json",
        "Accept" => "text/event-stream",
        "x-openclaw-session-key" => session_key
      }
      headers["Authorization"] = "Bearer #{@user.llm_api_key}" if @user&.llm_api_key.present?
      headers
    end

    def stream_response(payload, &block)
      retries = 0
      max_retries = CollavreOpenclaw.config.max_retries

      begin
        connection = build_connection
        buffer = +""
        request_headers = build_headers

        response = connection.post do |req|
          req.url api_endpoint
          request_headers.each { |k, v| req.headers[k] = v }
          req.body = payload.to_json

          req.options.on_data = proc do |chunk, _size, env|
            if env&.status.nil? || (env.status >= 200 && env.status < 300)
              buffer << chunk
              process_sse_buffer(buffer, &block)
            else
              buffer << chunk
            end
          end
        end

        unless response.status >= 200 && response.status < 300
          error_body = buffer.presence || response.body
          raise parse_error_message(response.status, error_body)
        end

        process_sse_buffer(buffer, final: true, &block)

        if response.headers["content-type"]&.include?("application/json")
          handle_json_response(response.body, &block)
        end

        response
      rescue Faraday::TimeoutError
        retries += 1
        if retries <= max_retries
          Rails.logger.warn("[CollavreOpenclaw] Timed out, retrying (#{retries}/#{max_retries})...")
          sleep(1 * retries)
          retry
        end
        raise "OpenClaw request timed out after #{max_retries + 1} attempts"
      rescue Faraday::ConnectionFailed => e
        retries += 1
        if retries <= max_retries
          Rails.logger.warn("[CollavreOpenclaw] Connection failed, retrying (#{retries}/#{max_retries})...")
          sleep(1 * retries)
          retry
        end
        raise "Failed to connect to OpenClaw after #{max_retries + 1} attempts: #{e.message}"
      end
    end

    def parse_error_message(status, body)
      detail = ""
      begin
        json = JSON.parse(body, symbolize_names: true) if body.present?
        detail = json[:error] || json[:message] || json.to_s if json
      rescue JSON::ParserError
        detail = body.to_s.truncate(200)
      end

      case status
      when 401 then "Authentication failed (HTTP 401). Check your API key. #{detail}"
      when 403 then "Access forbidden (HTTP 403). #{detail}"
      when 404 then "Gateway endpoint not found (HTTP 404). Check your Gateway URL."
      when 429 then "Rate limited (HTTP 429). #{detail}"
      when 500..599 then "Gateway server error (HTTP #{status}). #{detail}"
      else "HTTP #{status}: #{detail}"
      end
    end

    def handle_json_response(body, &block)
      json = JSON.parse(body, symbolize_names: true)
      content = json.dig(:choices, 0, :message, :content)
      yield content if content.present? && block_given?
    rescue JSON::ParserError
      # Ignore
    end

    def process_sse_buffer(buffer, final: false, &block)
      while (idx = buffer.index("\n\n"))
        event_data = buffer.slice!(0, idx + 2)
        parse_sse_event(event_data, &block)
      end

      if final && buffer.present?
        parse_sse_event(buffer, &block)
        buffer.clear
      end
    end

    def parse_sse_event(event_str, &block)
      event_str.each_line do |line|
        line = line.strip
        next if line.empty? || line.start_with?(":")

        next unless line.start_with?("data:")

        data = line.sub(/^data:\s*/, "")
        next if data == "[DONE]"

        begin
          json = JSON.parse(data, symbolize_names: true)
          content = extract_content(json)
          yield content if content.present?
        rescue JSON::ParserError
          yield data if data.present?
        end
      end
    end

    def extract_content(json)
      json.dig(:choices, 0, :delta, :content) ||
        json.dig(:choices, 0, :message, :content) ||
        json[:content] ||
        json[:text]
    end

    def build_connection
      Faraday.new do |builder|
        builder.options.timeout = CollavreOpenclaw.config.read_timeout
        builder.options.open_timeout = CollavreOpenclaw.config.open_timeout
        builder.adapter Faraday.default_adapter
      end
    end

    # ─────────────────────────────────────────────
    # Helpers
    # ─────────────────────────────────────────────

    def extract_id(context, key)
      value = context[key] || context[key.to_s]
      return nil unless value

      return value.id if value.respond_to?(:id)
      value[:id] || value["id"]
    end

    def extract_agent_id_from_email
      return nil unless @user&.email.present?
      @user.email.split("@").first
    end

    def default_url_options
      options = Rails.application.config.action_mailer.default_url_options || {}

      host = options[:host]
      host ||= Rails.application.config.action_controller.default_url_options&.dig(:host)
      host ||= ENV["APP_HOST"]
      host ||= ENV["RAILS_HOST"]

      result = { host: host }
      result[:protocol] = options[:protocol] || "https"
      result[:port] = options[:port] if options[:port].present?
      result
    end
  end
end
