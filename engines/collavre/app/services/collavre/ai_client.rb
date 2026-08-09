module Collavre
  class AiClient
    SYSTEM_INSTRUCTIONS = <<~PROMPT.freeze
      You are a senior expert teammate. Respond:
      - Be concise and focus on the essentials (avoid unnecessary verbosity).
      - Use short bullet points only when helpful.
      - State only what you're confident about; briefly note any uncertainty.
      - Respond in the asker's language (prefer the latest user message). Keep code and error messages in their original form.
    PROMPT

    attr_reader :last_input_tokens, :last_output_tokens

    # Did the last #chat end without the provider ever receiving the payload?
    #
    # #chat swallows a provider error: it streams "⚠️ AI Error" to the caller
    # and returns nil — which an ordinary empty answer also returns — so the
    # return value cannot tell the two apart. Orchestration::DeliveryRecord
    # needs them apart, because a turn that handed the provider nothing
    # delivered nothing, and AiAgentJob still marks such a turn `done`.
    #
    # An error *after* the provider started answering is not one of these. It
    # had the payload and acted on it; the truncated reply and the retry beside
    # it are the ordinary ending the product already shows, and the comments
    # that turn swallowed did reach the agent. "Started answering" is any chunk,
    # not any *content* — see the stream block for why a tool-call chunk is the
    # sharper case.
    def last_handoff_failed?
      @last_handoff_failed
    end

    # Whether the last #chat got its payload to the provider — the same
    # boundary, asked positively, for the callers the flag above cannot serve.
    #
    # #last_handoff_failed? is only ever set from a rescue, so it says nothing
    # about a #chat that left by exception past it: a user pressing Stop
    # mid-answer raises CancelledError through here, and the turn ends in a
    # status every reader counts as undelivered although the provider has the
    # payload. Answering that needs the fact recorded as it happens rather than
    # inferred from how the call ended.
    def handed_off?
      @handed_off
    end

    # Vendor <select> options for AI-agent config. Core ships only its built-in
    # (stateless) providers; vendor engines append their own through
    # register_vendor_option, so core never names a vendor engine.
    BASE_VENDOR_OPTIONS = [
      [ "Google (Gemini)", "google" ],
      [ "OpenAI", "openai" ],
      [ "Anthropic", "anthropic" ],
      [ "CLI Proxy", "cli_proxy" ]
    ].freeze

    class << self
      def registered_vendor_options
        @registered_vendor_options ||= []
      end

      # Append a vendor <select> option ([label, value]). Idempotent by value.
      def register_vendor_option(label, value)
        value = value.to_s
        return if BASE_VENDOR_OPTIONS.any? { |_l, v| v == value }
        return if registered_vendor_options.any? { |_l, v| v == value }

        registered_vendor_options << [ label, value ]
      end

      def vendor_options
        BASE_VENDOR_OPTIONS + registered_vendor_options
      end

      # Vendors that use stateful/incremental sessions. Base providers are
      # stateless; vendor engines that add session support register here so core
      # never string-matches a vendor name to decide session behavior.
      def session_vendors
        @session_vendors ||= Set.new
      end

      def register_session_vendor(vendor)
        session_vendors << vendor.to_s.downcase
      end

      def vendor_supports_session?(vendor)
        session_vendors.include?(vendor.to_s.downcase)
      end
    end

    # log_interactions: persist each call to ActivityLog. Default true. Pass false
    # for ephemeral, high-frequency calls on text the user has not submitted (e.g.
    # inline typo correction on debounced typing) so private drafts are never
    # written to server-side activity logs.
    #
    # before_tool_call: callable run before every tool execution, on every
    # iteration of the request->tools->request loop. This is the only
    # cancellation/deadline checkpoint a tool-only turn has: tool-call chunks
    # carry no content, so #chat never yields them to the caller's streaming
    # block, where the text path runs its check. A CancelledError raised here
    # propagates out of #chat as a cancellation, not an "⚠️ AI Error" delta.
    def initialize(vendor:, model:, system_prompt:, llm_api_key: nil, gateway_url: nil, context: {},
                   log_interactions: true, before_tool_call: nil, request_timeout_seconds: nil)
      @vendor = vendor
      @model = model
      @system_prompt = system_prompt
      @llm_api_key = llm_api_key
      @gateway_url = gateway_url
      @context = context
      @log_interactions = log_interactions
      @before_tool_call = before_tool_call
      @request_timeout_seconds = request_timeout_seconds
      @last_input_tokens = 0
      @last_output_tokens = 0
      @last_handoff_failed = false
      @handed_off = false
    end

    def chat(contents, tools: [], &block)
      @last_handoff_failed = false
      @handed_off = false
      response_content = +""
      error_message = nil
      input_tokens = nil
      output_tokens = nil

      normalized_vendor = vendor.to_s.downcase
      unless VENDOR_TO_PROVIDER.key?(normalized_vendor)
        Rails.logger.warn "Unsupported LLM vendor '#{@vendor}'. Attempting to use default (google)."
      end

      @conversation = build_conversation(tools)
      add_messages(@conversation, contents)

      response = @conversation.complete do |chunk|
        # A chunk at all is the provider having accepted the request and begun
        # answering — the earliest acceptance observable from here, and the
        # analogue of the gateway run id the OpenClaw adapter records.
        #
        # Set above the empty check, not below it: role-only and tool-call
        # chunks carry no content, and a conversation that reached its tools has
        # not merely been handed the payload, it has acted on it — this
        # product's tools write creatives and post comments. A turn classified
        # as a failed handoff has everything it swallowed dispatched again, and
        # the restored turn runs those tools a second time.
        @handed_off = true
        delta = extract_chunk_content(chunk).to_s
        # Deliberately NOT `blank?`. A delta of exactly "\n\n" — the paragraph
        # break, which providers routinely emit as a token of its own — is
        # blank? == true, so skipping blanks deletes it. And the deleted delta is
        # never yielded, so it is gone from the caller's stream too: AiAgentService
        # persists ResponseStreamer#content, which is built only from the yielded
        # deltas, and the reply lands in the database with its paragraphs glued
        # together. Only truly empty deltas (role-only / tool-call chunks carry no
        # content) are skippable.
        next if delta.empty?

        response_content << delta
        yield delta if block_given?
      end

      if response
        if response.content.present?
          response_content = response.content.to_s
          @handed_off = true
        end

        # Extract token usage directly from response object (RubyLLM style)
        if response.respond_to?(:input_tokens)
          input_tokens = response.input_tokens
        end

        if response.respond_to?(:output_tokens)
          output_tokens = response.output_tokens
        end
      end

      response_content.presence
    rescue ApprovalPendingError
      # Preserve conversation for follow-up (e.g. generating approval summary)
      raise
    rescue CancelledError
      raise # Re-raise cancellation errors without catching them
    rescue StandardError => e
      # Nothing came back at all means nothing was handed over — see
      # #last_handoff_failed?. Asked of @handed_off rather than of the buffer,
      # and not `blank?`: a delta of exactly "\n\n" is content the branch above
      # deliberately keeps, so `blank?` calls a stream that broke after a
      # paragraph break a failed handoff, and the buffer either way says nothing
      # about the content-less chunks. The two are the same
      # boundary asked two ways, and Task#ended_undelivered? reads a row carrying
      # both as undelivered — so it has to be impossible to record both.
      @last_handoff_failed = !@handed_off
      error_message = "[#{e.class.name}] #{e.message}"
      # When log_interactions is false (inline typo correction runs on the user's
      # *unsubmitted* draft), the LLM error message can echo the request text. Log
      # only the error class to app logs so private drafts never leak — matching the
      # no-log guarantee already enforced on the parse path (TypoCorrector) and the
      # ActivityLog gate below. error_message stays intact for the gated ensure log
      # and the streamed yield (which goes back to the same user).
      Rails.logger.error "AI Client error: #{@log_interactions ? error_message : "[#{e.class.name}]"}"
      log_error_response(e) if @log_interactions
      Rails.logger.error "Partial response length: #{response_content.length} chars" if response_content.present?
      Rails.logger.debug e.backtrace.join("\n")
      yield "\n\n⚠️ AI Error: #{error_message}" if block_given?
      nil
    ensure
      @last_input_tokens = input_tokens || 0
      @last_output_tokens = output_tokens || 0
      if @log_interactions
        log_interaction(
          messages: @conversation&.messages&.to_a || Array(contents),
          tools: @conversation&.tools&.to_a || [],
          response_content: response_content.presence,
          error_message: error_message,
          input_tokens: input_tokens,
          output_tokens: output_tokens
        )
      end
    end

    # Ask a follow-up question using the existing conversation context.
    # Used to generate approval summaries with full conversation history.
    # Returns the response content string, or nil on failure.
    def ask(prompt)
      return nil unless @conversation

      refresh_turn_boundary!(@conversation)
      # Disable tool calls for summary generation to avoid recursive approval
      @conversation.with_tools(replace: true)
      response = @conversation.ask(prompt)
      refresh_turn_boundary!(@conversation)
      response&.content&.strip.presence
    rescue CancelledError
      raise
    rescue StandardError => e
      # A provider timeout at the turn boundary must become the deadline that
      # caused it, not a missing summary followed by pending_approval.
      refresh_turn_boundary!(@conversation)
      Rails.logger.warn("AiClient#ask failed: #{e.class} #{e.message}")
      nil
    end

    private

    attr_reader :vendor, :model, :system_prompt, :llm_api_key, :gateway_url, :context

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

    VENDOR_TO_PROVIDER = {
      "openai" => :openai,
      "cli_proxy" => :openai,
      "anthropic" => :anthropic,
      "google" => :gemini,
      "gemini" => :gemini
    }.freeze

    def build_conversation(tools = [])
      normalized_vendor = @vendor.to_s.downcase

      context_block = case normalized_vendor
      when "openai", "cli_proxy"
        if normalized_vendor == "cli_proxy"
          agent = context[:user]
          gateway = agent&.agent_gateway
          raise ArgumentError, "CLI Proxy agent has no active gateway" unless gateway&.active?

          if context.key?(:workspace_user)
            workspace_user = context[:workspace_user]
          else
            comment_user = context[:comment]&.user
            workspace_user = comment_user unless comment_user&.ai_user?
            workspace_user ||= agent.creator
          end
          if gateway.per_user? && workspace_user.nil?
            raise ArgumentError, "CLI Proxy per-user workspace requires a verified human principal"
          end
          workspace_user = nil if gateway.shared?
          workspace = Collavre::AgentWorkspace.resolve!(agent: agent, user: workspace_user)
          gateway = workspace.agent_gateway
          @cli_proxy_identity = { gateway: gateway, workspace: workspace }
          api_key = gateway.completion_key
          base_url = gateway.completion_base_url
        else
          api_key = @llm_api_key.presence || IntegrationSettings.fetch(:openai_api_key)
          base_url = @gateway_url.presence
        end
        # A custom OpenAI-compatible gateway (local Ollama / LM Studio, etc.) needs
        # no real OpenAI key, but RubyLLM raises ConfigurationError before sending
        # if openai_api_key is blank. Supply a placeholder so keyless local gateways
        # work; hosted OpenAI (no gateway) still requires a real key.
        api_key = "local-gateway" if api_key.blank? && base_url
        proc do |config|
          config.openai_api_key = api_key
          config.openai_api_base = base_url if base_url
          if normalized_vendor == "cli_proxy" && !gateway.owner.system_admin?
            config.faraday_adapter = Collavre::CliProxy::SafeNetHttpAdapter
          end
        end
      when "anthropic"
        api_key = @llm_api_key.presence || IntegrationSettings.fetch(:anthropic_api_key)
        proc { |config| config.anthropic_api_key = api_key }
      else
        api_key = @llm_api_key.presence || IntegrationSettings.fetch(:gemini_api_key)
        proc { |config| config.gemini_api_key = api_key }
      end

      provider = VENDOR_TO_PROVIDER[normalized_vendor]
      chat_opts = { model: model }
      chat_opts[:provider] = provider if provider
      chat_opts[:assume_model_exists] = true if provider

      # RubyLLM::Context duplicates the global config. Set the timeout on that
      # per-client copy so concurrent agent threads cannot overwrite one
      # another's deadline cap.
      @ruby_llm_context = RubyLLM.context do |config|
        context_block.call(config)
        config.request_timeout = effective_request_timeout_seconds
      end

      @ruby_llm_context.chat(**chat_opts).tap do |chat|
        chat.with_instructions(system_prompt) if system_prompt.present?
        apply_request_headers!(chat)
        chat.on_tool_call do |tool_call|
          # Cancellation ahead of the approval gate: a turn that already
          # reached a terminal status or its deadline must end, not park
          # itself as pending approval for a tool it will never run. Force this
          # boundary through the lifecycle throttle: the first tool call can
          # arrive during the manager's initial one-second quiet period.
          @before_tool_call&.call(true)
          check_tool_approval!(tool_call)
        end
        if @request_timeout_seconds || @cli_proxy_identity
          chat.after_tool_result do |_result|
            # A tool can consume much of the turn. Recheck the deadline and
            # refresh request-scoped state before the loop starts its next
            # provider request.
            refresh_turn_boundary!(chat)
          end
        end
        if tools.any?
          # Resolve tool names to classes using the gem's helper
          tool_classes = ::Tools::MetaToolService.ruby_llm_tools(tools)
          chat.with_tools(*tool_classes, replace: true)
        end
      end
    end

    def refresh_turn_boundary!(conversation)
      if @request_timeout_seconds
        @before_tool_call&.call(true)
        if @ruby_llm_context
          @ruby_llm_context.config.request_timeout = effective_request_timeout_seconds
          conversation.with_context(@ruby_llm_context)
        end
      end

      apply_request_headers!(conversation)
    end

    def apply_request_headers!(conversation)
      headers = {}
      session_id = build_session_id
      headers["X-Session-Id"] = session_id if session_id

      if @cli_proxy_identity
        headers.merge!(Collavre::CliProxy::Identity.headers(
          **@cli_proxy_identity,
          method: :post,
          path: "/v1/chat/completions"
        ))
      end

      conversation.with_headers(**headers) if headers.present?
    end

    def effective_request_timeout_seconds
      configured = SystemSetting.llm_request_timeout_seconds.to_f
      remaining = @request_timeout_seconds&.call
      return configured unless remaining

      [ configured, remaining.to_f ].min.clamp(0.001, configured)
    end

    def build_session_id
      creative_id = context&.dig(:creative)&.id
      topic_id = context&.dig(:comment)&.topic_id || context&.dig(:topic_id)
      return nil unless creative_id && topic_id

      "creative_#{creative_id}_topic_#{topic_id}"
    end

    def check_tool_approval!(tool_call)
      tool_name = tool_call.name
      task = context&.dig(:task)

      # Check if this tool requires approval (dynamic McpTool or system tool)
      mcp_tool = McpTool.find_by(name: tool_name)
      system_tool_class = ToolMeta.registry.find { |klass| klass.tool_metadata[:name] == tool_name }
      requires = mcp_tool&.requires_approval? ||
                 (system_tool_class.respond_to?(:requires_approval?) && system_tool_class.requires_approval?)
      return unless requires

      # Check if we already have approval for this specific call (resume scenario)
      if task&.pending_tool_call.present?
        pending = task.pending_tool_call
        if pending["tool_name"] == tool_name && pending["approved"]
          # Already approved, clear the pending state and proceed
          task.update!(pending_tool_call: nil)
          return
        end
      end

      # Requires approval - raise error to halt execution
      raise ApprovalPendingError.new(
        "Tool '#{tool_name}' requires approval before execution",
        tool_call: tool_call,
        task: task
      )
    end

    def add_messages(conversation, contents)
      Array(contents).each do |message|
        next if message.nil?

        role = normalize_role(message)
        next unless role

        text = extract_message_text(message)
        image_sources = extract_image_sources(message)

        next if text.blank? && image_sources.empty?

        if image_sources.any?
          content = RubyLLM::Content.new(text.presence, image_sources)
          conversation.add_message(role:, content: content)
        else
          next if text.blank?

          conversation.add_message(role:, content: text)
        end
      end
    end

    def normalize_role(message)
      value = message[:role] || message["role"]
      case value.to_s
      when "user" then :user
      when "model", "assistant" then :assistant
      when "system" then :system
      when "function", "tool" then :tool
      else
        nil
      end
    end

    def extract_image_sources(message)
      parts = message[:parts] || message["parts"]
      return [] if parts.nil?

      Array(parts).filter_map { |part| part[:image] || part["image"] }
    end

    def extract_message_text(message)
      parts = message[:parts] || message["parts"]
      return message[:text] || message["text"] if parts.nil?

      Array(parts).map { |part| part[:text] || part["text"] }.compact.join("\n")
    end

    def extract_chunk_content(chunk)
      return if chunk.nil?

      if chunk.respond_to?(:content)
        chunk.content
      else
        chunk.to_s
      end
    end

    def log_interaction(messages:, tools:, response_content:, error_message: nil, input_tokens: nil, output_tokens: nil)
      RubyLlmInteractionLogger.log(
        vendor: @vendor,
        model: @model,
        messages: messages,
        tools: tools,
        response_content: response_content,
        error_message: error_message,
        creative: context&.dig(:creative),
        user: context&.dig(:user),
        comment: context&.dig(:comment),
        input_tokens: input_tokens,
        output_tokens: output_tokens
      )
    end
  end
end
