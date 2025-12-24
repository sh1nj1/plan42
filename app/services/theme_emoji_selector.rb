class ThemeEmojiSelector
  EMOJI_SETS = {
    nature: %w[🌿 🌱 🍃 🌼 🍀 🌳],
    night: %w[🌙 ⭐ 🌌 🌘 🌑 🌠],
    ocean: %w[🌊 🐚 🪸 🐬 🐠 🧜],
    pastel: %w[🌸 ✨ 🫧 💗 🧁 🎀],
    tech: %w[🤖 💾 🛰️ ⚡️ 🔋 📡],
    cozy: %w[☕️ 🧣 🕯️ 📚 🧶 🛋️]
  }.freeze

  KEYWORDS = {
    night: %w[night moon star galaxy cosmos cosmic lunar midnight starlight],
    ocean: %w[ocean sea wave beach coral shell tide marine],
    pastel: %w[pastel soft floral blossom bloom spring cherry],
    tech: %w[tech cyber neon circuit future futuristic ai digital],
    cozy: %w[cozy warm autumn latte coffee candle wood cabin hygge],
    nature: %w[nature forest green leaf garden moss meadow outdoors]
  }.freeze

  DEFAULT_SET = :nature

  def initialize(description)
    @description = description.to_s.downcase
  end

  def key
    KEYWORDS.each do |set, words|
      return set if words.any? { |word| @description.include?(word) }
    end

    DEFAULT_SET
  end

  def emoji_list
    EMOJI_SETS[key] || EMOJI_SETS[DEFAULT_SET]
  end

  def css_value
    emoji_list.join(" ")
  end
end
