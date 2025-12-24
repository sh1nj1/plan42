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
    --color-nav-btn-text
    --color-chat-btn-text
    --color-input-bg
    --color-input-text
    --color-nav-text
  ].freeze

  def initialize(client: default_client)
    @client = client
  end

  def generate(prompt)
    system_prompt = <<~PROMPT
      You are an expert UI/UX designer specialized in creating color themes for web applications.
      Your task is to generate a JSON object containing CSS variables.
      Generate a CSS theme as a JSON object based on the prompt: "#{prompt}".
      The JSON must strictly contain ONLY these keys: #{REQUIRED_VARIABLES.join(', ')}.

      CRITICAL DESIGN RULES:
      1. Use **only 'oklch()' color format** for all colors. Do not use hex, rgb, or hsl.
      2. Ensure "--color-nav-btn-text" has High Contrast (WCAG AA/AAA) against "--color-bg" (which is used as the button background in the nav).
      3. Ensure "--color-chat-btn-text" has High Contrast against "--color-section-bg" (where chat messages reside).
      4. Ensure "--color-nav-text" has High Contrast against "--color-nav-bg".
      5. Names of these text colors should be visually distinct from their background colors to ensure readability.
      6. Do not include any other keys or newlines.
      7. Return valid JSON only.

      The JSON object must strictly follow this structure:
      {
        "--color-bg": "oklch(95% 0.01 200)",
        "--color-text": "oklch(20% 0.02 200)",
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

    parsed = begin
      JSON.parse(cleaned)
    rescue JSON::ParserError => e
      Rails.logger.error("AutoThemeGenerator JSON Error: #{e.message}. Content: #{content}")
      {}
    end

    return {} unless parsed.is_a?(Hash)

    process_variables(parsed)
  end

  def process_variables(variables)
    variables.transform_values do |value|
      if value.is_a?(String) && value.start_with?("oklch(")
        convert_oklch_to_hex(value)
      else
        value
      end
    end
  end

  def convert_oklch_to_hex(oklch_str)
    # Parse oklch string: oklch(L C H [/ A])
    # Supports %, deg, and alpha channel
    # Example: oklch(60% 0.15 240deg / 0.5)
    # Regex matches:
    # 1. Lightness (number + optional %)
    # 2. Chroma (number + optional %)
    # 3. Hue (number + optional deg/rad/turn)
    # 4. Optional alpha (number + optional %)
    match = oklch_str.match(/oklch\(\s*([0-9.]+)%?\s+([0-9.]+)%?\s+([0-9.]+)(?:deg|rad|turn)?(?:\s*\/\s*([0-9.]+)%?)?\s*\)/)
    return oklch_str unless match

    l_val = match[1].to_f
    l_val /= 100.0 if oklch_str.include?("#{match[1]}%") && !match[1].include?(".") # Simple heuristic, or trust regex groups if I separated units.
    # Better to just handle the % if it was captured. My regex captures the number part separate from %.
    # Actually, the regex above `([0-9.]+)%?` captures ONLY the number in group 1.
    # So I need to check if the original string had % for that match.
    # Let's refine parsing.

    # Re-parsing carefully
    l_raw = match[1]
    l_val = l_raw.to_f
    l_val /= 100.0 if oklch_str =~ /#{Regexp.escape(l_raw)}%/

    c_val = match[2].to_f
    # Chroma usually doesn't have %, but if it does (rare), handle it? Standard is number.
    # Let's assume number.

    h_val = match[3].to_f
    # Hue is usually degrees if unitless or deg.
    # If rad/turn, conversion needed? Standard oklch is degrees-like?
    # CSS spec says oklch hue is angle. Deg is default.

    # Alpha: match[4]
    # We are currently ignoring alpha for 6-digit hex output.

    # 1. OKLCH to OKLab
    # h is in degrees, convert to radians
    h_rad = h_val * Math::PI / 180.0
    a_val = c_val * Math.cos(h_rad)
    b_val = c_val * Math.sin(h_rad)

    # 2. OKLab to Linear sRGB
    # Matrix values from standard implementation
    # Step 1: Lab to LMS (non-linear)
    l_non_linear = l_val + 0.3963377774 * a_val + 0.2158037573 * b_val
    m_non_linear = l_val - 0.1055613458 * a_val - 0.0638541728 * b_val
    s_non_linear = l_val - 0.0894841775 * a_val - 1.2914855480 * b_val

    # Step 2: Cube to get Linear LMS
    l = l_non_linear ** 3
    m = m_non_linear ** 3
    s = s_non_linear ** 3

    # Step 3: LMS to Linear sRGB
    r_linear = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    g_linear = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    b_linear = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

    # 3. Linear sRGB to sRGB (Gamma correction)
    r = linear_srgb_to_srgb(r_linear)
    g = linear_srgb_to_srgb(g_linear)
    b = linear_srgb_to_srgb(b_linear)

    # 4. To Hex
    to_hex(r, g, b)
  end

  def linear_srgb_to_srgb(c)
    val = if c <= 0.0031308
            12.92 * c
    else
            1.055 * (c ** (1.0 / 2.4)) - 0.055
    end
    # Clamp between 0 and 1
    [ [ val, 0.0 ].max, 1.0 ].min
  end

  def to_hex(r, g, b)
    r_int = (r * 255).round
    g_int = (g * 255).round
    b_int = (b * 255).round
    sprintf("#%02x%02x%02x", r_int, g_int, b_int)
  end
end
