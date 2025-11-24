class AiClient
  SYSTEM_INSTRUCTIONS = <<~PROMPT.freeze
    You are a senior expert teammate. Respond:
    - Be concise and focus on the essentials (avoid unnecessary verbosity).
    - Use short bullet points only when helpful.
    - State only what you're confident about; briefly note any uncertainty.
    - Respond in the asker's language (prefer the latest user message). Keep code and error messages in their original form.
  PROMPT

  def initialize(vendor:, model:, system_prompt:, llm_api_key: nil)
    @vendor = vendor
    @model = model
    @system_prompt = system_prompt
    @llm_api_key = llm_api_key
  end

  def chat(contents, &block)
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

    vendor = @vendor.to_s.downcase
    unless %w[google gemini].include?(vendor)
      Rails.logger.warn "Unsupported LLM vendor '#{@vendor}'. Attempting to use default (google)."
    end

    conversation = build_conversation
    add_messages(conversation, contents)

    response = conversation.complete do |chunk|
      delta = extract_chunk_content(chunk)
      next if delta.blank?

      yield delta if block_given?
    end

    response&.content
  rescue StandardError => e
    Rails.logger.error "AI Client error: #{e.message}"
    yield "AI Error: #{e.message}" if block_given?
    nil
  end

  private

  attr_reader :vendor, :model, :system_prompt, :llm_api_key

  def build_conversation
    # Using RubyLLM.context to ensure we can potentially switch keys if we had them.
    # We explicitly set the key from ENV for now, as RubyLLM might not pick it up from global config in context?
    # Or maybe the global config was not loaded in the runner context properly?
    # Regardless, setting it here ensures it works like GeminiChatClient.

    api_key = @llm_api_key.presence || ENV["GEMINI_API_KEY"]
    RubyLLM.context { |config| config.gemini_api_key = api_key }
           .chat(model: model).tap do |chat|
      chat.with_instructions(system_prompt)
    end
  end

  def add_messages(conversation, contents)
    Array(contents).each do |message|
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
end
