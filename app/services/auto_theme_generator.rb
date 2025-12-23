class AutoThemeGenerator
  REQUIRED_VARIABLES = %w[
    --color-bg
    --color-text
    --color-link
    --color-nav-bg
    --color-section-bg
    --color-btn-bg
    --color-btn-text
    --color-border
    --color-muted
    --color-complete
    --color-chip-bg
    --color-drag-over
    --color-drag-over-edge
    --hover-brightness
    --color-badge-bg
    --color-badge-text
    --color-secondary-active
    --color-secondary-background
  ].freeze

  def initialize(client: default_client)
    @client = client
  end

  def generate(prompt)
    system_prompt = <<~PROMPT
      You are an expert UI/UX designer specialized in creating color themes for web applications.
      Your task is to generate a JSON object containing CSS variables for a theme described by the user.

      The JSON object must strictly follow this structure:
      {
        "--color-bg": "hex or color value",
        "--color-text": "hex or color value",
        ...
      }

      REQUIRED VARIABLES:
      #{REQUIRED_VARIABLES.join("\n")}

      GUIDELINES:
      - Ensure high contrast between text and background.
      - Maintain a consistent aesthetic suitable for the description.
      - Return ONLY the JSON object. No markdown formatting, no explanations.
    PROMPT

    response = @client.chat([
      { role: :system, parts: [ { text: system_prompt } ] },
      { role: :user, parts: [ { text: "Create a theme description: #{prompt}" } ] }
    ])

    parse_response(response)
  end

  private

  def default_client
    AiClient.new(
      vendor: "google",
      model: "gemini-2.5-flash",
      system_prompt: nil
    )
  end

  def parse_response(content)
    return {} if content.blank?

    # Remove markdown code blocks if present
    cleaned = content.gsub(/^```json\s*/, "").gsub(/\s*```$/, "")

    begin
      JSON.parse(cleaned)
    rescue JSON::ParserError => e
      Rails.logger.error("AutoThemeGenerator JSON Error: #{e.message}. Content: #{content}")
      {}
    end
  end
end
