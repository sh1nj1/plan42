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
    return if api_key.blank?

    conversation = build_conversation
    add_messages(conversation, contents)

    response = conversation.complete do |chunk|
      delta = extract_chunk_content(chunk)
      next if delta.blank?

      yield delta if block_given?
    end

    response&.content
  rescue StandardError => e
    Rails.logger.error("Gemini chat error: #{e.message}")
    yield "Gemini error: #{e.message}" if block_given?
    nil
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
