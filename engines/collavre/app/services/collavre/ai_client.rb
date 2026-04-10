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

    def initialize(vendor:, model:, system_prompt:, llm_api_key: nil, gateway_url: nil, context: {})
      @vendor = vendor
      @model = model
      @system_prompt = system_prompt
      @llm_api_key = llm_api_key
      @gateway_url = gateway_url
      @context = context
      @last_input_tokens = 0
      @last_output_tokens = 0
    end

    def chat(contents, tools: [], &block)
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
        delta = extract_chunk_content(chunk)
        next if delta.blank?

        response_content << delta
        yield delta if block_given?
      end

      if response
        response_content = response.content.to_s if response.content.present?

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
      error_message = "[#{e.class.name}] #{e.message}"
      Rails.logger.error "AI Client error: #{error_message}"
      Rails.logger.error "Partial response length: #{response_content.length} chars" if response_content.present?
      Rails.logger.debug e.backtrace.join("\n")
      yield "\n\n⚠️ AI Error: #{error_message}" if block_given?
      nil
    ensure
      @last_input_tokens = input_tokens || 0
      @last_output_tokens = output_tokens || 0
      log_interaction(
        messages: @conversation&.messages&.to_a || Array(contents),
        tools: @conversation&.tools&.to_a || [],
        response_content: response_content.presence,
        error_message: error_message,
        input_tokens: input_tokens,
        output_tokens: output_tokens
      )
    end

    # Ask a follow-up question using the existing conversation context.
    # Used to generate approval summaries with full conversation history.
    # Returns the response content string, or nil on failure.
    def ask(prompt)
      return nil unless @conversation

      # Disable tool calls for summary generation to avoid recursive approval
      @conversation.with_tools(replace: true)
      response = @conversation.ask(prompt)
      response&.content&.strip.presence
    rescue StandardError => e
      Rails.logger.warn("AiClient#ask failed: #{e.class} #{e.message}")
      nil
    end

    private

    attr_reader :vendor, :model, :system_prompt, :llm_api_key, :gateway_url, :context

    VENDOR_TO_PROVIDER = {
      "openai" => :openai,
      "anthropic" => :anthropic,
      "google" => :gemini,
      "gemini" => :gemini
    }.freeze

    def build_conversation(tools = [])
      normalized_vendor = @vendor.to_s.downcase

      context_block = case normalized_vendor
      when "openai"
        api_key = @llm_api_key.presence || ENV["OPENAI_API_KEY"]
        base_url = @gateway_url.presence
        proc do |config|
          config.openai_api_key = api_key
          config.openai_api_base = base_url if base_url
        end
      when "anthropic"
        api_key = @llm_api_key.presence || ENV["ANTHROPIC_API_KEY"]
        proc { |config| config.anthropic_api_key = api_key }
      else
        api_key = @llm_api_key.presence || ENV["GEMINI_API_KEY"]
        proc { |config| config.gemini_api_key = api_key }
      end

      provider = VENDOR_TO_PROVIDER[normalized_vendor]
      chat_opts = { model: model }
      chat_opts[:provider] = provider if provider
      chat_opts[:assume_model_exists] = true if provider

      # Apply current system timeout setting (picks up changes without restart)
      RubyLLM.config.request_timeout = SystemSetting.llm_request_timeout_seconds

      RubyLLM.context(&context_block)
             .chat(**chat_opts).tap do |chat|
        chat.with_instructions(system_prompt) if system_prompt.present?
        chat.on_tool_call do |tool_call|
          check_tool_approval!(tool_call)
        end
        if tools.any?
          # Resolve tool names to classes using the gem's helper
          tool_classes = ::Tools::MetaToolService.ruby_llm_tools(tools)
          chat.with_tools(*tool_classes, replace: true)
        end
      end
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
