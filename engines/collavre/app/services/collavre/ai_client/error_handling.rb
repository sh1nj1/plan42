module Collavre
  class AiClient
    module ErrorHandling
      private

      def report_chat_error(e, response_content)
        raise_cli_proxy_login_error(e)

        error_message = "[#{e.class.name}] #{e.message}"
        # When log_interactions is false, an LLM error message can echo request text.
        # Log only the error class so sensitive content never leaks. error_message
        # stays intact for the gated ensure log and streamed yield to the caller.
        Rails.logger.error "AI Client error: #{@log_interactions ? error_message : "[#{e.class.name}]"}"
        log_error_response(e) if @log_interactions
        Rails.logger.error "Partial response length: #{response_content.length} chars" if response_content.present?
        Rails.logger.debug e.backtrace.join("\n")
        error_message
      end

      def raise_cli_proxy_login_error(error)
        return unless vendor == "cli_proxy" && @cli_proxy_identity

        login_error = CliProxy::EngineUnauthenticatedError.from_response(error, workspace: @cli_proxy_identity[:workspace])
        raise login_error if login_error
      end

      # RubyLLM masks provider 400s behind a generic "Invalid request - please check
      # your input" fallback whenever the provider's error body is not in OpenAI's
      # {error:{message}} shape — common for OpenAI-compatible gateways (Cerebras,
      # local Ollama, etc.), whose real reason then lives only in the raw HTTP
      # response. RubyLLM::Error carries that response (status + body); surface it so
      # the actual cause is one grep away instead of buried in ruby_llm.log.
      #
      # A provider 400 body can echo the offending request (prompt or tool arguments),
      # so the raw body is written to the app log only under debug logging — the same
      # level that already gates RubyLLM's own request/response body log (see the
      # ruby_llm initializer). At INFO (production) we record status + body size only,
      # keeping user content out of centralized app logs while still capturing that the
      # provider rejected the request and how large its reason was; raise the log level
      # to recover the full body on demand. The whole path is additionally gated by
      # @log_interactions at the call site, like the error-message log above.
      def log_error_response(error)
        return unless error.respond_to?(:response) && (response = error.response)

        status = response.respond_to?(:status) ? response.status : nil
        body = response.respond_to?(:body) ? response.body : nil
        return if status.nil? && body.blank?

        unless Rails.logger.debug?
          size = body.is_a?(String) ? "#{body.bytesize}B" : (body.nil? ? "none" : "non-string")
          Rails.logger.error "AI Client error response: status=#{status} body_size=#{size} " \
                             "(body suppressed at INFO; raise log level to capture it)"
          return
        end

        # Provider error bodies are frequently tagged ASCII-8BIT even though the bytes
        # are valid UTF-8; reinterpret and scrub so non-ASCII text (e.g. Korean) is
        # readable and never re-triggers the transcode failure we are eliminating.
        body_text = body.is_a?(String) ? body.dup.force_encoding("UTF-8").scrub : body.inspect
        Rails.logger.error "AI Client error response: status=#{status} body=#{body_text.to_s.truncate(2000)}"
      rescue StandardError => e
        Rails.logger.debug "AiClient#log_error_response failed: #{e.class}"
      end
    end
  end
end
