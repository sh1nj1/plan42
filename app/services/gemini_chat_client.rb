class GeminiChatClient
  DEFAULT_MODEL = "gemini-2.5-flash".freeze
  SYSTEM_INSTRUCTIONS = <<~PROMPT.freeze
    You are a senior expert teammate. Respond:
    - Be concise and focus on the essentials (avoid unnecessary verbosity).
    - Use short bullet points only when helpful.
    - State only what you're confident about; briefly note any uncertainty.
    - Respond in the asker's language (prefer the latest user message). Keep code and error messages in their original form.
  PROMPT

  def initialize(api_key: ENV["GEMINI_API_KEY"], model: DEFAULT_MODEL, chat_factory: default_chat_factory)
    @api_key = api_key
    @model = model
    @chat_factory = chat_factory
  end

  def chat(contents, &block)
    normalized_messages = []
    response_content = +""
    error_message = nil

    return if api_key.blank?

    conversation = build_conversation
    normalized_messages = add_messages(conversation, contents)

    response = conversation.complete do |chunk|
      delta = extract_chunk_content(chunk)
      next if delta.blank?

      response_content << delta
      yield delta if block_given?
    end

    response_content = response&.content.to_s if response&.content.present?
    response_content.presence
  rescue StandardError => e
    error_message = e.message
    Rails.logger.error("Gemini chat error: #{e.message}")
    yield "Gemini error: #{e.message}" if block_given?
    nil
  ensure
    log_interaction(
      messages: normalized_messages.presence || Array(contents),
      response_content: response_content.presence,
      error_message: error_message
    )
  end

  private

  attr_reader :api_key, :model, :chat_factory

  def default_chat_factory
    lambda do |model_id, api_key|
      RubyLLM.context { |config| config.gemini_api_key = api_key }
             .chat(model: model_id)
    end
  end

  def build_conversation
    chat_factory.call(model, api_key).tap do |chat|
      chat.with_instructions(SYSTEM_INSTRUCTIONS)
    end
  end

  def add_messages(conversation, contents)
    normalized = []
    Array(contents).each do |message|
      next if message.nil?

      role = normalize_role(message)
      next unless role

      text = extract_message_text(message)
      next if text.blank?

      conversation.add_message(role:, content: text)
      normalized << { role:, parts: [ { text: text } ] }
    end

    normalized
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

  def log_interaction(messages:, response_content:, error_message: nil)
    RubyLlmInteractionLogger.log(
      vendor: "google",
      model: model,
      system_prompt: SYSTEM_INSTRUCTIONS,
      messages: messages,
      tools: [],
      response_content: response_content,
      error_message: error_message
    )
  end
end
