module Collavre
  class AiClient
    include ErrorHandling
    include Decision, ProviderContext
    include AiUsageTracking, AiApprovalSummary, ApprovalGate, CliToolEvents
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
      [ "TypesafeAI", "typesafe" ],
      [ "Anthropic", "anthropic" ],
      [ "CLI Proxy", "cli_proxy" ]
    ].freeze

    class << self
      def registered_vendor_options
        @registered_vendor_options ||= []
      end

      # Append a vendor <select> option ([label, value]). Idempotent by value.
      def register_vendor_option(label, value)
        value = value.to_s.strip.downcase
        return if BASE_VENDOR_OPTIONS.any? { |_l, v| v == value }
        return if registered_vendor_options.any? { |_l, v| v == value }

        registered_vendor_options << [ label, value ]
      end

      def register_vendor_capabilities(vendor, capabilities:)
        vendor_capabilities[vendor.to_s.strip.downcase] = capabilities.map(&:to_sym).freeze
      end

      def vendor_capabilities
        @vendor_capabilities ||= { "openai" => %i[chat judge], "typesafe" => %i[judge] }
      end

      def supports?(vendor, capability, model: nil)
        vendor = vendor.to_s.strip.downcase
        capability = capability.to_sym
        return false unless vendor_capabilities.fetch(vendor, %i[chat]).include?(capability)
        return false if capability == :judge && !VENDOR_TO_PROVIDER.key?(vendor)
        return true unless vendor == "openai" && capability == :judge && !model.nil?

        RubyLLM::Providers::OpenAI::Capabilities.augment([], model_id: model).include?("judgment")
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
        session_vendors << vendor.to_s.strip.downcase
      end

      def vendor_supports_session?(vendor)
        session_vendors.include?(vendor.to_s.strip.downcase)
      end
    end

    # log_interactions: persist each call to ActivityLog. Default true. Pass false
    # when a caller must not persist sensitive request or response content.
    #
    # before_tool_call: callable run before every tool execution, on every
    # iteration of the request->tools->request loop. This is the only
    # cancellation/deadline checkpoint a tool-only turn has: tool-call chunks
    # carry no content, so #chat never yields them to the caller's streaming
    # block, where the text path runs its check. A CancelledError raised here
    # propagates out of #chat as a cancellation, not an "⚠️ AI Error" delta.
    def initialize(vendor:, model:, system_prompt:, llm_api_key: nil, gateway_url: nil, context: {},
                   log_interactions: true, before_tool_call: nil, request_timeout_seconds: nil)
      @vendor = vendor.to_s.strip.downcase
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

      prepare_gate_conversation(contents, tools)

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
        # Marked before observe_chunk: a listener there may raise CancelledError,
        # and the chunk that reached it is already proof of handoff.
        @handed_off = true
        observe_chunk(chunk)
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

        input_tokens = response.tokens&.input
        output_tokens = response.tokens&.output
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
      error_message = report_chat_error(e, response_content)
      yield "\n\n⚠️ AI Error: #{error_message}" if block_given?
      nil
    ensure
      finalize_chat_usage(response, contents, response_content, error_message, input_tokens, output_tokens)
    end

    private

    attr_reader :vendor, :model, :system_prompt, :llm_api_key, :gateway_url, :context

    VENDOR_TO_PROVIDER = {
      "openai" => :openai,
      "typesafe" => :typesafe,
      "cli_proxy" => :openai,
      "anthropic" => :anthropic,
      "google" => :gemini,
      "gemini" => :gemini
    }.freeze

    def build_conversation(tools = [])
      build_llm_context.chat(**conversation_options(@vendor)).tap do |chat|
        chat.with_instructions(system_prompt) if system_prompt.present?
        apply_request_headers!(chat)
        install_tool_boundary(chat)
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
          chat.with_tools(*tool_classes)
        end
      end
    end

    def conversation_options(normalized_vendor)
      provider = VENDOR_TO_PROVIDER[normalized_vendor]
      options = { model: model }
      options[:provider] = provider if provider
      options[:protocol] = :chat_completions if provider == :openai
      options[:assume_model_exists] = true if provider
      options
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
      check_approval_gate!(tool_call)
      tool_name = tool_call.name
      task = context&.dig(:task)

      return unless ToolApprovalPolicy.required_for_call?(tool_call, agent: task&.agent)

      # Requires approval - raise error to halt execution
      raise ApprovalPendingError.new(
        "Tool '#{tool_name}' requires approval before execution",
        tool_call: tool_call,
        task: task,
        messages: AiAgent::ApprovalConversation.dump(@conversation&.messages || [])
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

        attributes = { role: role, content: text.presence }
        attributes[:attachments] = image_sources if image_sources.any?
        conversation.add_message(**attributes)
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
      return message[:text] || message["text"] || message[:content] || message["content"] if parts.nil?

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
  end
end
