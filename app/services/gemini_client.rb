class GeminiClient
  DEFAULT_MODEL = "gemini-2.5-flash".freeze

  def initialize(api_key: ENV["GEMINI_API_KEY"], model: DEFAULT_MODEL, chat_factory: default_chat_factory)
    @api_key = api_key
    @model = model
    @chat_factory = chat_factory
  end

  def recommend_parent_ids(tree_text, description)
    prompt = nil
    response_content = nil
    error_message = nil

    return [] if @api_key.blank?

    prompt = build_prompt(tree_text, description)
    Rails.logger.info("### prompt=#{prompt}")

    response = chat.ask(prompt)
    response_content = response&.content&.to_s
    parse_response(response_content)
  rescue StandardError => e
    error_message = e.message
    Rails.logger.error("GeminiClient recommendation failed: #{e.class} #{e.message}")
    []
  ensure
    log_interaction(
      prompt: prompt,
      response_content: response_content,
      error_message: error_message
    ) if @api_key.present?
  end

  private

  def default_chat_factory
    lambda do |model_id, api_key|
      RubyLLM.context { |config| config.gemini_api_key = api_key }
             .chat(model: model_id)
    end
  end

  def chat
    @chat ||= @chat_factory.call(@model, @api_key)
  end

  def build_prompt(tree_text, description)
    "#{tree_text}\n\nGiven the above creative tree, which ids are the best parents for \"#{description}\"? " \
      "Reply with up to 5 ids separated by commas in descending order of relevance."
  end

  def parse_response(content)
    return [] if content.blank?

    content.to_s.split(/[\s,]+/)
           .filter_map { |value| Integer(value, exception: false) }
           .reject(&:zero?)
           .first(5)
  end

  def log_interaction(prompt:, response_content:, error_message: nil)
    RubyLlmInteractionLogger.log(
      vendor: "google",
      model: @model,
      messages: [ { role: :user, parts: [ { text: prompt } ] } ],
      tools: [],
      response_content: response_content,
      error_message: error_message
    )
  end
end
