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

        UI LAYOUT — UNDERSTAND WHERE EACH TOKEN APPEARS:
        The app has this visual structure (top to bottom):
        ┌──────────────────────────────────────────────┐
        │  NAV BAR (--surface-nav)  LARGE, full width  │
        │  [search input] [홈][계획][완료] [avatar]      │
        │  Text: --text-nav  Buttons: --text-nav-btn   │
        ├──────────────────────────────────────────────┤
        │  TOOLBAR (--surface-bg background)           │
        │  [+][선택][▼][마크다운 가져오기] ← small btns │
        │  Buttons use: --surface-btn + --text-on-btn  │
        ├──────────────────────────────────────────────┤
        │  MAIN CONTENT (--surface-bg) LARGEST area    │
        │  Text: --text-primary                        │
        │  Cards/sections: --surface-section           │
        │  Links: --color-link                         │
        │  Muted text: --text-muted                    │
        ├──────────────────────────────────────────────┤
        │  CHAT POPUP (--surface-section)              │
        │  Chat buttons: --text-chat-btn               │
        │  Input fields: --surface-input + --text-input│
        └──────────────────────────────────────────────┘

        AREA SIZES (critical for visual balance):
        - --surface-bg: ~60% of screen — THE dominant color, must be the most neutral
        - --surface-nav: ~8% — top bar, can be slightly more saturated/darker
        - --surface-section: ~20% — cards and panels
        - --surface-btn: ~2% — small interactive elements (buttons)
        - --surface-input: ~5% — form fields
        - --color-brand/link/active: <1% — tiny accent points, can be vivid
        - --text-primary: covers lots of area as text — must contrast well with bg

        COLOR STRATEGY:
        Think of it like interior design: walls (surfaces) are neutral, furniture (buttons) has subtle contrast, and decorations (accents) provide pops of color.

        Step 1 — Extract a MOOD COLOR from the prompt (e.g. "tomato" → warm red, "grape" → deep purple, "forest" → muted green).
        Step 2 — The mood color should appear as the BRAND/ACCENT color (vivid, small areas).
        Step 3 — Surfaces should be TINTED NEUTRALS of the mood:
          - For "tomato": warm cream/beige backgrounds, not bright red surfaces
          - For "grape": cool lavender-gray backgrounds, not purple surfaces
          - For "banana": warm ivory backgrounds, not yellow surfaces
          Surface chroma should be LOW (C=0.01–0.03). The tint is felt, not seen.
          ALL surfaces must share the SAME hue family. Do NOT mix warm and cool surfaces.

        Step 4 — LIGHTNESS STAIRCASE (critical for visual separation):
          Light themes (surface-bg L≈95%):
            --surface-bg:        L=93–97%  (brightest, the "white wall")
            --surface-input:     L=91–95%  (almost same as bg, slightly warmer)
            --surface-section:   L=87–91%  (noticeably darker than bg)
            --surface-secondary: L=85–89%  (similar to section)
            --surface-nav:       L=80–86%  (clearly darker, the "header bar")
            --surface-btn:       L=75–82%  (darkest surface, clearly a "button")
          Dark themes (surface-bg L≈10–15%):
            --surface-bg:        L=8–15%
            --surface-input:     L=12–18%
            --surface-section:   L=15–22%
            --surface-secondary: L=15–22%
            --surface-nav:       L=5–12%   (darker than bg, like a dark header)
            --surface-btn:       L=20–30%  (lighter than bg, clearly tappable)
          The KEY is that each surface is visually distinguishable from its neighbors.
          If you squint, you should see 3-4 distinct zones, not a flat monotone.

        Step 5 — Nav bar should be the MOST distinctly colored surface:
          It's the persistent top bar. It can have slightly more chroma (C=0.03–0.06) than other surfaces.
        Step 6 — Buttons (--surface-btn) must STAND OUT from the background:
          They're interactive elements. Users must immediately see them as clickable.
          In light themes: btn should be noticeably darker than bg (≥15 L-points difference)
          In dark themes: btn should be noticeably lighter than bg (≥10 L-points difference)
        Step 7 — Text must have WCAG AA contrast (≥4.5:1) against its paired surface:
          --text-primary   vs --surface-bg
          --text-on-btn    vs --surface-btn
          --text-input     vs --surface-input
          --text-nav       vs --surface-nav
          --text-nav-btn   vs --surface-bg
          --text-chat-btn  vs --surface-section
          --text-muted     ≥3:1 against --surface-bg
          --text-on-badge  vs --color-badge-bg
        Step 8 — Accent colors:
          --color-brand: The mood color at full saturation (C=0.15–0.25)
          --color-link: Same as or near brand
          --color-active: Lighter/brighter variant of brand
          --color-accent-border / --color-accent-text: Brand family
        Step 9 — Semantic colors (standard associations, slightly tinted):
          --color-danger:  Red (H≈25–30)
          --color-success: Green (H≈145–155)
          --color-warning: Amber (H≈85–95)
          --color-badge-bg: Red or brand
        Step 10 — Utility:
          --color-highlight: Warm translucent (L≈85%, C≈0.08, H≈90)
          --color-code-bg: SAME hue as surface-bg, just 3-5% darker. Do NOT use a different color family.
          --color-code-text: High contrast against code-bg, same hue family as text-primary
          --border-color: Between surface-bg and text lightness, very low chroma
          --border-drag-over/edge: Slightly stronger

        CRITICAL MISTAKES TO AVOID:
        - Do NOT make --surface-bg highly saturated. It covers 60% of the screen. Keep it nearly neutral.
        - Do NOT use the mood color directly as a surface. "Tomato" theme ≠ red background. It means warm-tinted neutrals with red accents.
        - Do NOT make surfaces all the same lightness. You MUST follow the lightness staircase in Step 4.
          BAD:  bg=#edf7fe, section=#ddeefb, nav=#c7e2f6 (only 5-10% apart)
          GOOD: bg=#f5f8fa, section=#e8ecef, nav=#c5cdd5, btn=#a0abb5 (15-20% apart)
        - Do NOT pick unrelated colors for code-bg. It must match the surface hue family.
          BAD:  surface-bg=#fff7ee (warm), code-bg=#e3edf4 (cool blue) — jarring mismatch
          GOOD: surface-bg=#fff7ee (warm), code-bg=#f0ead8 (warm, slightly darker) — harmonious
        - Do NOT make buttons invisible against the background. --surface-btn must differ from --surface-bg by ≥15 L-points.
        - For multi-color prompts (e.g. "Google logo", "rainbow"): use the dominant color for surfaces, distribute other colors across accent tokens (brand, active, badge-bg, accent-border).
        - Borders must be visible but not distracting.
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
