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

        === UI LAYOUT (know what each token controls) ===
        ┌─────────────────────────────────────────┐
        │ NAV BAR (--surface-nav)        ~8% area │
        │ [brand logo] [nav buttons]              │
        ├─────────────────────────────────────────┤
        │ MAIN CONTENT (--surface-bg)    ~60% area│
        │                                         │
        │  ┌─ SECTION ──────────────────────────┐ │
        │  │ (--surface-section)        ~15%    │ │
        │  │  ┌─INPUT──┐  ┌──BTN──┐            │ │
        │  │  │ input   │  │ Save  │   ~2% each│ │
        │  │  └─────────┘  └───────┘            │ │
        │  └────────────────────────────────────┘ │
        │                                         │
        │  ┌─ SECONDARY ────┐ ┌─ CODE ────────┐  │
        │  │ sidebar ~10%   │ │ code-bg  ~3%  │  │
        │  └────────────────┘ └────────────────┘  │
        └─────────────────────────────────────────┘
        Think of it like interior design:
        - surface-bg = WALLS (60%) — tinted with theme color, light/pastel
        - surface-section = FLOOR (15%) — slightly deeper shade
        - surface-nav = CEILING/TRIM (8%) — noticeably deeper
        - surface-btn = FURNITURE (2%) — can be vivid or deep
        - Accents (brand, active, badge) = DECORATIONS — small pops of color

        === PROCESS ===

        Step 1) INTERPRET THE PROMPT → extract a HUE:
           "토마토" → warm red hue (25°). "숲" → green hue (145°).
           "바나나" → yellow hue (90°). "바다" → blue hue (230°).
           Multi-color (e.g. "Google logo"=blue+red+yellow+green):
             Pick the DOMINANT color's hue for surfaces.
             Distribute ALL distinct colors across accent tokens:
             brand=color1, active=color2, badge-bg=color3, accent-border=color4.
             The user must SEE each named color clearly. Do NOT blend into gray.

        Step 2) BUILD SURFACES — TINTED, not gray!
           ALL surfaces must carry the theme's hue. Use the SAME hue with varying lightness AND chroma.
           GOOD examples (surfaces carry color):
             바나나: bg=#fdf7d0 (yellow tint), section=#feeec1, nav=#e8d36b, btn=#e3b831
             숲속:   bg=#ecf4ef (green tint), section=#e2f4e7, nav=#d5e2d7, btn=#357153
             토마토: bg=#fbefea (warm pink),   section=#f5e8e4, nav=#f7ded6, btn=#cc0000
           BAD examples (color stripped out):
             바나나: bg=#f1eee7 (gray beige) ← WRONG, no yellow
             숲속:   bg=#eaeff5 (gray blue)  ← WRONG, no green

           Lightness staircase (light theme):
             bg=93-97%, input=91-95%, section=87-91%, secondary=85-89%, nav=80-86%, btn=40-80%
           Lightness staircase (dark theme):
             bg=8-15%, input=14-20%, section=18-24%, secondary=18-22%, nav=6-12%, btn=22-32%

           Chroma guidance:
             bg/input: LOW chroma (C=0.02-0.06) — tinted but soft
             section/secondary: MEDIUM (C=0.03-0.08)
             nav: MEDIUM-HIGH (C=0.05-0.12)
             btn: HIGH is OK (C=0.05-0.20) — can be vivid or deep

        Step 3) TEXT — must contrast against its background:
           LIGHT themes: text-primary/on-btn/nav/input = L≤25% (near black). text-muted = L≤40%.
           DARK themes: text-primary/on-btn/nav/input = L≥80% (near white). text-muted = L≥60%.
           Exception: if btn is very dark (L<40%), text-on-btn should be LIGHT (L≥85%).
           Exception: if nav is very dark (L<40%), text-nav should be LIGHT (L≥85%).
           CRITICAL: ≥4.5:1 contrast ratio for all text/surface pairs.

        Step 4) ACCENTS — vivid mood color:
           brand/link = mood color at full saturation. active = brighter variant.
           danger=red, success=green, warning=amber (standard, always).
           code-bg = SAME hue as surface-bg, just 3-5% darker.
           border-color = between surface-bg and text-primary in lightness.

        === CRITICAL MISTAKES TO AVOID ===
        - NEVER make surfaces gray/neutral when the prompt has a clear color (the #1 mistake)
        - NEVER make text-on-btn similar lightness to surface-btn
        - NEVER make all surfaces the same lightness (need clear staircase)
        - For multi-color prompts: NEVER blend all colors into one muddy tone
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
