module Collavre
  class AutoThemeGenerator
    REQUIRED_VARIABLES = %w[
      --surface-bg
      --surface-nav
      --surface-section
      --surface-input
      --surface-btn
      --surface-secondary
      --text-primary
      --text-muted
      --text-on-btn
      --text-nav
      --text-nav-btn
      --text-chat-btn
      --text-on-badge
      --text-input
      --color-link
      --color-brand
      --color-active
      --color-danger
      --color-success
      --color-warning
      --color-highlight
      --color-badge-bg
      --color-accent-border
      --color-accent-text
      --color-code-bg
      --color-code-text
      --border-color
      --border-drag-over
      --border-drag-edge
      --hover-brightness
      --creative-loading-emojis
    ].freeze

    def initialize(client: default_client)
      @client = client
    end

    def generate(prompt)
      system_prompt = <<~PROMPT
        You are a color theme designer for a workspace app.
        Generate a JSON with ONLY these keys: #{REQUIRED_VARIABLES.join(', ')}.

        FORMAT: oklch() for colors. --hover-brightness: "90%" (light) or "110%" (dark).
        --creative-loading-emojis: 6 emojis. Return valid JSON only, no markdown.

        === PROCESS ===

        1) INTERPRET THE PROMPT:
           - Single mood (e.g. "tomato", "ocean"): extract one mood color → use as brand/accent.
           - Multi-color (e.g. "Google logo"=blue+red+yellow+green, "rainbow", "Italian flag"):
             Surfaces stay NEUTRAL. Distribute the distinct colors across accents:
             brand=color1, active=color2, badge-bg=color3, accent-border=color4.
             The user must SEE each color separately — do NOT blend into monotone.

        2) BUILD SURFACES — lightness staircase, same hue, LOW chroma (C≤0.03):
           Light theme:  bg=95%, input=93%, section=88%, secondary=86%, nav=82%, btn=76%
           Dark theme:   bg=12%, input=16%, section=20%, secondary=20%, nav=8%, btn=26%
           "Tomato" → warm cream surfaces, NOT red. "Grape" → cool gray, NOT purple.

        3) TEXT — must be DARK on light surfaces, LIGHT on dark surfaces:
           For LIGHT themes: text-primary/on-btn/nav/input = L≤25% (near black). text-muted = L≤40%.
           For DARK themes: text-primary/on-btn/nav/input = L≥80% (near white). text-muted = L≥60%.
           CRITICAL: --text-on-btn MUST contrast against --surface-btn (≥4.5:1).
           CRITICAL: --text-nav MUST contrast against --surface-nav (≥4.5:1).

        4) ACCENTS — vivid mood color:
           brand/link = mood at full saturation. active = brighter variant.
           danger=red, success=green, warning=amber (standard).
           code-bg = same hue as bg, 5% darker. border-color = between bg and text.

        === HARD RULES ===
        - bg covers 60% of screen. Keep it NEARLY WHITE or NEARLY BLACK.
        - btn L must differ from bg L by ≥15 points.
        - ALL text tokens on light surfaces must be DARK (L≤25%). No light-on-light.
        - ALL surfaces share the same hue. code-bg too.
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
end
