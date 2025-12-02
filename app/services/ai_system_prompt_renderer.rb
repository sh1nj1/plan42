class AiSystemPromptRenderer
  def self.render(template:, context: {})
    new(template:, context:).render
  end

  def initialize(template:, context: {})
    @template = template.presence || AiClient::SYSTEM_INSTRUCTIONS
    @context = context
  end

  def render
    parsed_template.render(stringified_context, render_options)
  rescue StandardError => e
    Rails.logger.warn("AI system prompt rendering failed: #{e.message}")
    template
  end

  private

  attr_reader :template, :context

  def parsed_template
    Liquid::Template.parse(template, error_mode: :warn)
  end

  def stringified_context
    context.deep_stringify_keys
  end

  def render_options
    {
      strict_variables: false,
      strict_filters: false
    }
  end
end
