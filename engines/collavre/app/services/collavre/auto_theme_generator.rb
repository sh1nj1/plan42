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
        You are an expert UI/UX designer creating a color theme for a collaborative workspace app.
        Generate a CSS theme as a JSON object for: "#{prompt}".
        The JSON must contain ONLY these keys: #{REQUIRED_VARIABLES.join(', ')}.

        FORMAT RULES:
        - Use **oklch()** for ALL colors (except --hover-brightness and --creative-loading-emojis).
        - --hover-brightness: a CSS filter percentage (e.g. "90%" for light themes, "110%" for dark themes).
        - --creative-loading-emojis: exactly 6 emojis matching the theme mood, comma-separated.
        - Return valid JSON only. No markdown, no explanation.

        COLOR HARMONY — THIS IS CRITICAL:
        First, decide the theme's overall tone (light or dark) based on the prompt.
        Then derive ALL colors from a single cohesive palette:

        Step 1 — Pick a BASE HUE (H) that matches the mood. Most surfaces should share this hue.
        Step 2 — Build surfaces as a GRADIENT of lightness on that hue:
          Light theme example (L from high to low):
            --surface-bg:        L=96%  (lightest, page background)
            --surface-section:   L=98%  (cards, slightly lighter or same)
            --surface-nav:       L=94%  (nav bar, slightly darker)
            --surface-input:     L=96%  (input fields, same as bg)
            --surface-btn:       L=90%  (buttons, noticeably darker)
            --surface-secondary: L=98%  (secondary areas)
          Dark theme: invert — L ranges from 15% to 30%.
          Keep chroma (C) LOW for surfaces (0.01–0.04). Surfaces should feel neutral-tinted.

        Step 3 — Text colors must have WCAG AA contrast (≥4.5:1) against their paired surface:
          --text-primary   vs --surface-bg       (main content text)
          --text-on-btn    vs --surface-btn      (button labels)
          --text-input     vs --surface-input    (form text)
          --text-nav       vs --surface-nav      (nav links)
          --text-nav-btn   vs --surface-bg       (toolbar buttons over page)
          --text-chat-btn  vs --surface-section  (chat area buttons)
          --text-muted     — lower contrast but still readable (≥3:1)
          --text-on-badge  — white or dark, contrasting --color-badge-bg

        Step 4 — Accent colors share the base hue family or a complementary hue:
          --color-brand:   Saturated version of the theme hue (C=0.15–0.25)
          --color-link:    Same as brand or slightly shifted
          --color-active:  Brighter/lighter variant of brand
          --color-accent-border / --color-accent-text: Derived from brand

        Step 5 — Semantic colors (keep standard associations but tint toward theme):
          --color-danger:  Red family (H≈25–30)
          --color-success: Green family (H≈145–155)
          --color-warning: Yellow/amber family (H≈85–95)
          --color-badge-bg: Red or brand color

        Step 6 — Utility tokens:
          --color-highlight: Low-opacity warm highlight (L≈85%, C≈0.1, H≈90)
          --color-code-bg:  Slightly darker/lighter than --surface-bg
          --color-code-text: High contrast against code-bg
          --border-color:   Subtle, low chroma, between surface-bg and text lightness
          --border-drag-over / --border-drag-edge: Slightly stronger borders

        COMMON MISTAKES TO AVOID:
        - Do NOT pick random colors for each token. They must look like ONE theme.
        - Do NOT make surfaces too saturated (C > 0.05). Surfaces should be subtle.
        - Do NOT make buttons the same lightness as the background — they must be distinguishable.
        - Do NOT forget that --surface-btn and --surface-input are interactive elements users click/type in — they need to stand out slightly from --surface-bg.
        - Borders should be visible but subtle — not the same as surface-bg.
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
