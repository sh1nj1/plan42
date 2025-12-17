class AiClient
  SYSTEM_INSTRUCTIONS = <<~PROMPT.freeze
    You are a senior expert teammate. Respond:
    - Be concise and focus on the essentials (avoid unnecessary verbosity).
    - Use short bullet points only when helpful.
    - State only what you're confident about; briefly note any uncertainty.
    - Respond in the asker's language (prefer the latest user message). Keep code and error messages in their original form.
  PROMPT

  def initialize(vendor:, model:, system_prompt:, llm_api_key: nil, context: {})
    @vendor = vendor
    @model = model
    @system_prompt = system_prompt
    @llm_api_key = llm_api_key
    @context = context
  end

  def chat(contents, tools: [], &block)
    response_content = +""
    error_message = nil
    input_tokens = nil
    output_tokens = nil

    # For now, we assume the API key is in the environment variable GEMINI_API_KEY
    # In a real generic implementation, we might need to fetch keys based on vendor.
    # Since the user request mentioned "ruby_llm", we try to use it.
    # However, RubyLLM configuration in this project seems to be static in initializer.
    # We might need to adjust RubyLLM usage to be dynamic if possible, or just support Gemini for now via RubyLLM
    # but allowing model configuration.

    # Current RubyLLM initializer:
    # RubyLLM.configure do |config|
    #   config.gemini_api_key = ENV["GEMINI_API_KEY"]
    # end

    # We can use RubyLLM.context to override config per request if needed,
    # but for now we'll stick to the pattern in GeminiChatClient but make it slightly more generic
    # if RubyLLM supports other vendors.

    # NOTE: The current requirement implies we should support what RubyLLM supports.
    # If the user enters vendor='google', we use Gemini.

    # For now, we assume the API key is in the environment variable GEMINI_API_KEY
    # In a real generic implementation, we might need to fetch keys based on vendor.
    # Since the user request mentioned "ruby_llm", we try to use it.
    # Previously the method returned early unless vendor was "google" which caused AI responses
    # to be omitted for agents with a different or nil vendor. We now proceed for any vendor
    # and log a warning if the vendor is unsupported.

    normalized_vendor = vendor.to_s.downcase
    unless %w[google gemini].include?(normalized_vendor)
      Rails.logger.warn "Unsupported LLM vendor '#{@vendor}'. Attempting to use default (google)."
    end

    conversation = build_conversation(tools)
    add_messages(conversation, contents)

    response = conversation.complete do |chunk|
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
  rescue StandardError => e
    error_message = e.message
    Rails.logger.error "AI Client error: #{e.message}"
    Rails.logger.debug e.backtrace.join("\n")
    yield "AI Error: #{e.message}" if block_given?
    nil
  ensure
    log_interaction(
      messages: conversation.messages.to_a || Array(contents),
      tools: conversation.tools.to_a,
      response_content: response_content.presence,
      error_message: error_message,
      input_tokens: input_tokens,
      output_tokens: output_tokens
    )
  end

  private

  attr_reader :vendor, :model, :system_prompt, :llm_api_key, :context

  def build_conversation(tools = [])
    # Using RubyLLM.context to ensure we can potentially switch keys if we had them.
    # We explicitly set the key from ENV for now, as RubyLLM might not pick it up from global config in context?
    # Or maybe the global config was not loaded in the runner context properly?
    # Regardless, setting it here ensures it works like GeminiChatClient.

    api_key = @llm_api_key.presence || ENV["GEMINI_API_KEY"]
    RubyLLM.context { |config| config.gemini_api_key = api_key }
           .chat(model: model).tap do |chat|
      chat.with_instructions(system_prompt) if system_prompt.present?
      chat.on_tool_call do |tool_call|
        # You can do on_tool_call, on_tool_result hook by ruby llm provides
        # Rails.logger.info("Tool call: #{JSON.pretty_generate(tool_call.to_h)}")
      end
      if tools.any?
        # Resolve tool names to classes using the gem's helper
        tool_classes = Tools::MetaToolService.ruby_llm_tools(tools)
        chat.with_tools(*tool_classes, replace: true)
      end
    end
  end

  def add_messages(conversation, contents)
    Array(contents).each do |message|
      next if message.nil?

      role = normalize_role(message)
      next unless role

      text = extract_message_text(message)
      next if text.blank?

      conversation.add_message(role:, content: text)
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
