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
      --creative-h1-size
      --creative-h2-size
      --creative-h3-size
      --creative-h1-weight
      --creative-h2-weight
      --creative-h3-weight
      --creative-h1-color
      --creative-h2-color
      --creative-h3-color
      --creative-childless-size
      --creative-childless-weight
      --creative-bullet-size
      --creative-bullet-color
      --creative-tree-line-color
      --creative-tree-line-opacity
      --creative-h1-bg
      --creative-h2-bg
      --creative-h3-bg
    ].freeze

    def initialize(client: default_client)
      @client = client
    end

    def generate(prompt)
      system_prompt = <<~PROMPT
        You are a color theme designer for a workspace app.
        Generate a JSON with ONLY these keys: #{REQUIRED_VARIABLES.join(', ')}.

        FORMAT: hex colors (#rrggbb). --hover-brightness: "90%" (light) or "110%" (dark).
        --creative-loading-emojis: 6 emojis. Return ONLY valid JSON, no markdown.

        === REFERENCE THEMES (these are GOOD — match this quality) ===

        "바나나" (yellow, light):
        {"--surface-bg":"#fdf7d0","--surface-nav":"#e8d36b","--surface-section":"#feeec1",
         "--surface-input":"#ffffff","--surface-btn":"#e3b831","--surface-secondary":"#f4d9bb",
         "--text-primary":"#1a1200","--text-muted":"#5a4e00","--text-on-btn":"#241100",
         "--text-nav":"#1a1200","--text-nav-btn":"#1a1200","--text-chat-btn":"#1a1200",
         "--text-on-badge":"#fff8e0","--text-input":"#1a1200",
         "--color-link":"#c69900","--color-brand":"#c69900","--color-active":"#c08500",
         "--color-danger":"#cc3300","--color-success":"#4a8c00","--color-warning":"#cc8800",
         "--color-highlight":"#fff3a0","--color-badge-bg":"#ca9600",
         "--color-accent-border":"#a67a00","--color-accent-text":"#c69900",
         "--color-code-bg":"#f5efc0","--color-code-text":"#1a1200",
         "--border-color":"#c4b060","--border-drag-over":"#d4a800","--border-drag-edge":"#c69900",
         "--hover-brightness":"90%","--creative-loading-emojis":"🍌🌻💛🍋✨🌼",
         "--creative-h1-size":"1.3em","--creative-h2-size":"1.2em","--creative-h3-size":"1.1em",
         "--creative-h1-weight":"700","--creative-h2-weight":"600","--creative-h3-weight":"500",
         "--creative-h1-color":"#1a1200","--creative-h2-color":"#1a1200","--creative-h3-color":"#5a4e00",
         "--creative-childless-size":"1em","--creative-childless-weight":"400",
         "--creative-bullet-size":"5px","--creative-bullet-color":"#1a1200",
         "--creative-tree-line-color":"#c4b060","--creative-tree-line-opacity":"0.5",
         "--creative-h1-bg":"transparent","--creative-h2-bg":"transparent","--creative-h3-bg":"transparent"}

        "숲속" (green, light):
        {"--surface-bg":"#ecf4ef","--surface-nav":"#d5e2d7","--surface-section":"#e2f4e7",
         "--surface-input":"#f6f9f7","--surface-btn":"#357153","--surface-secondary":"#dbe8e3",
         "--text-primary":"#0a1f10","--text-muted":"#3a5040","--text-on-btn":"#f3fbf6",
         "--text-nav":"#0a1f10","--text-nav-btn":"#0a1f10","--text-chat-btn":"#0a1f10",
         "--text-on-badge":"#f3fbf6","--text-input":"#0a1f10",
         "--color-link":"#25984d","--color-brand":"#25984d","--color-active":"#008a39",
         "--color-danger":"#cc3300","--color-success":"#00880a","--color-warning":"#cc8800",
         "--color-highlight":"#c8f0d0","--color-badge-bg":"#005734",
         "--color-accent-border":"#337344","--color-accent-text":"#1a3520",
         "--color-code-bg":"#e0ede4","--color-code-text":"#0a1f10",
         "--border-color":"#a0bca6","--border-drag-over":"#40905a","--border-drag-edge":"#25984d",
         "--hover-brightness":"90%","--creative-loading-emojis":"🌲🍃🌿🌱✨🦎",
         "--creative-h1-size":"1.3em","--creative-h2-size":"1.15em","--creative-h3-size":"1.05em",
         "--creative-h1-weight":"700","--creative-h2-weight":"600","--creative-h3-weight":"500",
         "--creative-h1-color":"#0a1f10","--creative-h2-color":"#0a1f10","--creative-h3-color":"#3a5040",
         "--creative-childless-size":"1em","--creative-childless-weight":"400",
         "--creative-bullet-size":"5px","--creative-bullet-color":"#25984d",
         "--creative-tree-line-color":"#a0bca6","--creative-tree-line-opacity":"0.5",
         "--creative-h1-bg":"transparent","--creative-h2-bg":"transparent","--creative-h3-bg":"transparent"}

        "토마토" (red/warm, light):
        {"--surface-bg":"#fbefea","--surface-nav":"#f7ded6","--surface-section":"#f5e8e4",
         "--surface-input":"#fff6f3","--surface-btn":"#cc0000","--surface-secondary":"#f0cfc4",
         "--text-primary":"#1f0800","--text-muted":"#5a3020","--text-on-btn":"#fff0e8",
         "--text-nav":"#1f0800","--text-nav-btn":"#1f0800","--text-chat-btn":"#1f0800",
         "--text-on-badge":"#fff0e8","--text-input":"#1f0800",
         "--color-link":"#d40924","--color-brand":"#d40924","--color-active":"#ff4040",
         "--color-danger":"#cc0000","--color-success":"#4a8c00","--color-warning":"#cc8800",
         "--color-highlight":"#ffe0d0","--color-badge-bg":"#ba0d01",
         "--color-accent-border":"#c85b32","--color-accent-text":"#b22800",
         "--color-code-bg":"#f0e4de","--color-code-text":"#1f0800",
         "--border-color":"#d0a898","--border-drag-over":"#e04020","--border-drag-edge":"#cc0000",
         "--hover-brightness":"90%","--creative-loading-emojis":"🍅🔴🌶️🫕✨🍝",
         "--creative-h1-size":"1.3em","--creative-h2-size":"1.2em","--creative-h3-size":"1.1em",
         "--creative-h1-weight":"700","--creative-h2-weight":"600","--creative-h3-weight":"500",
         "--creative-h1-color":"#1f0800","--creative-h2-color":"#1f0800","--creative-h3-color":"#5a3020",
         "--creative-childless-size":"1em","--creative-childless-weight":"400",
         "--creative-bullet-size":"5px","--creative-bullet-color":"#d40924",
         "--creative-tree-line-color":"#d0a898","--creative-tree-line-opacity":"0.5",
         "--creative-h1-bg":"transparent","--creative-h2-bg":"transparent","--creative-h3-bg":"transparent"}

        "사이버펑크" (neon, dark):
        {"--surface-bg":"#070b14","--surface-nav":"#0f101f","--surface-section":"#12161f",
         "--surface-input":"#02060d","--surface-btn":"#2f1d4a","--surface-secondary":"#181b1f",
         "--text-primary":"#dcdde5","--text-muted":"#8a8c99","--text-on-btn":"#e0d0ff",
         "--text-nav":"#dcdde5","--text-nav-btn":"#dcdde5","--text-chat-btn":"#dcdde5",
         "--text-on-badge":"#dcdde5","--text-input":"#dcdde5",
         "--color-link":"#0099f0","--color-brand":"#e749df","--color-active":"#0089e9",
         "--color-danger":"#ff3050","--color-success":"#00cc66","--color-warning":"#ffaa00",
         "--color-highlight":"#2a1848","--color-badge-bg":"#692278",
         "--color-accent-border":"#0094c9","--color-accent-text":"#eb63c5",
         "--color-code-bg":"#0e1220","--color-code-text":"#c0c4d0",
         "--border-color":"#2a2e3a","--border-drag-over":"#6030a0","--border-drag-edge":"#e749df",
         "--hover-brightness":"110%","--creative-loading-emojis":"🌃💜⚡🤖✨🎮",
         "--creative-h1-size":"1.4em","--creative-h2-size":"1.2em","--creative-h3-size":"1.1em",
         "--creative-h1-weight":"800","--creative-h2-weight":"600","--creative-h3-weight":"500",
         "--creative-h1-color":"#e749df","--creative-h2-color":"#0099f0","--creative-h3-color":"#8a8c99",
         "--creative-childless-size":"1em","--creative-childless-weight":"400",
         "--creative-bullet-size":"4px","--creative-bullet-color":"#e749df",
         "--creative-tree-line-color":"#2a2e3a","--creative-tree-line-opacity":"0.7",
         "--creative-h1-bg":"#0f101f","--creative-h2-bg":"#12161f","--creative-h3-bg":"transparent"}

        === RULES ===

        1) SURFACES must be TINTED with the theme color — never gray or neutral.
           bg is lightest (pastel), then input, section, secondary, nav (deeper), btn (deepest or vivid).
        2) ALL text must be DARK (#0a-#2f range) on light themes, LIGHT (#cc-#ff range) on dark themes.
           Exception: text-on-btn must contrast with surface-btn. If btn is dark, text-on-btn is light.
        3) brand/link = vivid theme color. danger=red, success=green, warning=amber ALWAYS.
        4) code-bg = same hue as surface-bg, slightly darker. NEVER a different hue family.
        5) Multi-color prompts (e.g. "Google logo", "rainbow", "Italian flag"):
           - Surfaces: use the DOMINANT color's hue (tinted, not gray)
           - Distribute each distinct color to: brand, active, badge-bg, accent-border, accent-text
           - Each color must be RECOGNIZABLE — never blend into one muddy tone
        6) Match the vibe: "토마토" = warm reds/oranges, "바나나" = bright yellows, "숲" = rich greens.
           The user should IMMEDIATELY recognize the theme from its colors.
        7) CREATIVE TREE STYLING — the app has a hierarchical list (outliner) with levels:
           - Level 1-3: headings (h1/h2/h3). Level 4+: bullet items.
           - Items at level 1-3 WITHOUT children render as plain text (childless style).
           - creative-h{1,2,3}-size: font size (em units). h1 largest, descending. Range: 1.0em-1.5em.
           - creative-h{1,2,3}-weight: font weight. h1 boldest. Values: 400-800.
           - creative-h{1,2,3}-color: heading colors. Use text-primary or theme accent for h1.
             h3 can use muted color. MUST be readable on surface-bg.
           - creative-childless-size: usually 1em (normal text size).
           - creative-childless-weight: usually 400 (normal weight).
           - creative-bullet-size: bullet dot diameter in px. Range: 3px-6px.
           - creative-bullet-color: bullet color. Can match brand or text-primary.
           - creative-tree-line-color: vertical guide line color. Usually border-color or muted.
           - creative-tree-line-opacity: 0.3-0.8. Subtle but visible.
           - creative-h{1,2,3}-bg: heading row background color. Usually "transparent".
             For dark/accent themes, h1 can use a subtle darker surface. Must not clash with text.
           - For playful themes, vary heading colors. For minimal themes, keep sizes uniform.
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
        model: "gemini-3-flash-preview",
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
