require "faraday"
require "json"

module CollavreOpenclaw
  class OpenclawAdapter
    # Adapter for OpenClaw AI Gateway
    # Uses OpenAI-compatible /v1/chat/completions endpoint

    def initialize(user:, system_prompt:, context: {})
      @user = user
      @system_prompt = system_prompt
      @context = context
      @account = user&.openclaw_account
    end

    def chat(messages, tools: [], &block)
      unless @account
        Rails.logger.error("[CollavreOpenclaw] No OpenClaw account configured for user #{@user&.id}")
        yield "Error: OpenClaw account not configured" if block_given?
        return nil
      end

      response_content = +""

      begin
        # Build the request payload (OpenAI format)
        payload = build_payload(messages, tools)

        Rails.logger.info("[CollavreOpenclaw] Sending request to #{api_endpoint}")

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

    private

    def api_endpoint
      # OpenClaw uses /v1/chat/completions (OpenAI-compatible)
      uri = URI.parse(@account.gateway_url)
      uri.path = "/v1/chat/completions"
      uri.to_s
    end

    def build_payload(messages, tools)
      payload = {
        model: "openclaw",
        messages: format_messages(messages),
        stream: true
      }

      # Add system prompt as first message if present
      if @system_prompt.present?
        payload[:messages].unshift({ role: "system", content: @system_prompt })
      end

      # Add user identifier for session continuity
      if @account.channel_id.present?
        payload[:user] = "collavre:#{@account.channel_id}"
      end

      payload
    end

    def format_messages(messages)
      Array(messages).map do |msg|
        role = msg[:role] || msg["role"]
        parts = msg[:parts] || msg["parts"]
        content = if parts
                    Array(parts).map { |p| p[:text] || p["text"] }.compact.join("\n")
                  else
                    msg[:text] || msg["text"] || msg[:content] || msg["content"]
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
      connection = build_connection

      buffer = +""

      response = connection.post do |req|
        req.url api_endpoint
        req.headers["Content-Type"] = "application/json"
        req.headers["Accept"] = "text/event-stream"
        req.headers["Authorization"] = "Bearer #{@account.api_token}" if @account.api_token.present?
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
    rescue Faraday::TimeoutError
      raise "OpenClaw request timed out"
    rescue Faraday::ConnectionFailed => e
      raise "Failed to connect to OpenClaw: #{e.message}"
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
        builder.options.timeout = CollavreOpenclaw.config.request_timeout
        builder.options.open_timeout = 10
        builder.adapter Faraday.default_adapter
      end
    end

    def extract_id(context, key)
      value = context[key] || context[key.to_s]
      return nil unless value

      return value.id if value.respond_to?(:id)
      value[:id] || value["id"]
    end
  end
end
