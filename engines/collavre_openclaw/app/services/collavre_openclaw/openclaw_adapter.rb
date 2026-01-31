require "faraday"
require "json"

module CollavreOpenclaw
  class OpenclawAdapter
    # Adapter for OpenClaw AI Gateway
    # Implements the same interface as AiClient for seamless integration

    def initialize(user:, system_prompt:, context: {})
      @user = user
      @system_prompt = system_prompt
      @context = context
      @account = user.openclaw_account
    end

    def chat(messages, tools: [], &block)
      unless @account
        Rails.logger.error("[CollavreOpenclaw] No OpenClaw account configured for user #{@user.id}")
        yield "Error: OpenClaw account not configured" if block_given?
        return nil
      end

      response_content = +""

      begin
        # Build the request payload
        payload = build_payload(messages, tools)

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

    def build_payload(messages, tools)
      {
        messages: format_messages(messages),
        system_prompt: @system_prompt,
        tools: tools.presence,
        context: {
          creative_id: @context.dig(:creative, :id) || @context.dig("creative", "id"),
          user_id: @user.id,
          channel_id: @account.channel_id
        }.compact,
        stream: true
      }.compact
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

        { role: normalize_role(role), content: content }
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

      # Use SSE streaming for real-time responses
      buffer = +""

      response = connection.post do |req|
        req.url @account.api_endpoint
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

      response
    rescue Faraday::TimeoutError
      raise "OpenClaw request timed out"
    rescue Faraday::ConnectionFailed => e
      raise "Failed to connect to OpenClaw: #{e.message}"
    end

    def process_sse_buffer(buffer, final: false, &block)
      # Process complete SSE events from the buffer
      while (idx = buffer.index("\n\n"))
        event_data = buffer.slice!(0, idx + 2)
        parse_sse_event(event_data, &block)
      end

      # Handle final chunk that might not end with \n\n
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
            # Not JSON, might be plain text
            yield data if data.present?
          end
        end
      end
    end

    def extract_content(json)
      # Handle various response formats
      json[:content] ||
        json[:delta]&.dig(:content) ||
        json[:choices]&.first&.dig(:delta, :content) ||
        json[:text]
    end

    def build_connection
      Faraday.new do |builder|
        builder.options.timeout = CollavreOpenclaw.config.request_timeout
        builder.options.open_timeout = 10
        builder.adapter Faraday.default_adapter
      end
    end
  end
end
