require "faraday"
require "json"

module CollavreOpenclaw
  class OpenclawAdapter
    # Adapter for OpenClaw AI Gateway
    # Uses OpenAI-compatible /v1/chat/completions endpoint
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

    def chat(messages, tools: [], &block)
      unless @user&.gateway_url.present?
        Rails.logger.error("[CollavreOpenclaw] No Gateway URL configured for user #{@user&.id}")
        yield "Error: OpenClaw Gateway URL not configured" if block_given?
        return nil
      end

      response_content = +""

      begin
        # Build the request payload (OpenAI format)
        payload = build_payload(messages, tools)

        Rails.logger.info("[CollavreOpenclaw] Sending request to #{api_endpoint} (session: #{session_key})")

        # Make streaming request to OpenClaw
        stream_response(payload) do |chunk|
          response_content << chunk
          yield chunk if block_given?
        end

        response_content.presence
      rescue StandardError => e
        Rails.logger.error("[CollavreOpenclaw] Chat error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        error_msg = "OpenClaw Error: #{e.message}"
        yield error_msg if block_given?
        nil
      end
    end

    # Get the callback URL for this user
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

    def api_endpoint
      # OpenClaw uses /v1/chat/completions (OpenAI-compatible)
      uri = URI.parse(@user.gateway_url)
      uri.path = "/v1/chat/completions"
      uri.to_s
    end

    # Build stable session key based on Topic (not nonce)
    # Same Topic = Same Session = Shared context between users
    def build_session_key
      creative_id = extract_id(@context, :creative) || @context[:creative_id]
      topic_id = @context[:thread_id] || @context[:topic_id]

      parts = [ "collavre", @user.id ]
      parts << "creative:#{creative_id}" if creative_id
      parts << "topic:#{topic_id}" if topic_id

      parts.join(":")
    end

    def build_payload(messages, tools)
      # Build model string with agent_id derived from user email
      # OpenClaw accepts "openclaw:<agentId>" format (e.g., "openclaw:collavre")
      agent_id = extract_agent_id_from_email
      model_value = agent_id.present? ? "openclaw:#{agent_id}" : "openclaw"

      payload = {
        model: model_value,
        messages: format_messages(messages),
        stream: true
      }

      # Add system prompt as first message if present
      if @system_prompt.present?
        payload[:messages].unshift({ role: "system", content: @system_prompt })
      end

      # Build user context with callback information
      payload[:user] = build_user_context

      payload
    end

    def build_user_context
      context_data = {}

      # Extract IDs from context
      creative_id = extract_id(@context, :creative) || @context[:creative_id]
      comment_id = extract_id(@context, :comment) || @context[:comment_id]
      topic_id = @context[:thread_id] || @context[:topic_id]

      # Create pending callback with nonce for secure async responses
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

        Rails.logger.info("[CollavreOpenclaw] Created pending callback with nonce: #{pending.nonce[0..8]}...")
      end

      # Return as JSON string (OpenAI user field format)
      if context_data.any?
        "collavre:#{JSON.generate(context_data)}"
      else
        "collavre:#{@user.id}"
      end
    end

    # Format messages with sender attribution for multi-user context
    def format_messages(messages)
      Array(messages).map do |msg|
        role = msg[:role] || msg["role"]
        parts = msg[:parts] || msg["parts"]
        content = if parts
                    Array(parts).map { |p| p[:text] || p["text"] }.compact.join("\n")
        else
                    msg[:text] || msg["text"] || msg[:content] || msg["content"]
        end

        # Add sender attribution for user messages (multi-user support)
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

    def stream_response(payload, &block)
      retries = 0
      max_retries = CollavreOpenclaw.config.max_retries

      begin
        connection = build_connection
        buffer = +""

        response = connection.post do |req|
          req.url api_endpoint
          req.headers["Content-Type"] = "application/json"
          req.headers["Accept"] = "text/event-stream"

          # Set stable session key for topic-based context sharing
          req.headers["x-openclaw-session-key"] = session_key

          req.body = payload.to_json

          req.options.on_data = proc do |chunk, _size, _env|
            buffer << chunk
            process_sse_buffer(buffer, &block)
          end
        end

        # Process any remaining data in buffer
        process_sse_buffer(buffer, final: true, &block)

        # Handle non-streaming response
        if response.headers["content-type"]&.include?("application/json")
          handle_json_response(response.body, &block)
        end

        response
      rescue Faraday::TimeoutError => e
        retries += 1
        if retries <= max_retries
          Rails.logger.warn("[CollavreOpenclaw] Request timed out, retrying (#{retries}/#{max_retries})...")
          sleep(1 * retries)  # Exponential backoff
          retry
        end
        raise "OpenClaw request timed out after #{max_retries + 1} attempts (read_timeout: #{CollavreOpenclaw.config.read_timeout}s)"
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

        if line.start_with?("data:")
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
    end

    def extract_content(json)
      # OpenAI streaming format
      json.dig(:choices, 0, :delta, :content) ||
        json.dig(:choices, 0, :message, :content) ||
        json[:content] ||
        json[:text]
    end

    def build_connection
      Faraday.new do |builder|
        builder.options.timeout = CollavreOpenclaw.config.read_timeout      # Read timeout (3 min default)
        builder.options.open_timeout = CollavreOpenclaw.config.open_timeout # Connection timeout (10s)
        builder.adapter Faraday.default_adapter
      end
    end

    def extract_id(context, key)
      value = context[key] || context[key.to_s]
      return nil unless value

      return value.id if value.respond_to?(:id)
      value[:id] || value["id"]
    end

    # Extract agent_id from user email
    # e.g., "ai-agent@collavre.com" -> "ai-agent"
    def extract_agent_id_from_email
      return nil unless @user&.email.present?

      # Extract local part (before @) from email
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
