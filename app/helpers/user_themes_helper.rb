module UserThemesHelper
  def loading_emoji_options
    ThemeEmojiSelector::EMOJI_SETS.map do |key, emojis|
      label = I18n.t("themes.emoji_sets.#{key}", default: key.to_s.humanize)
      [ "#{label} (#{emojis.join(' ')})", key ]
    end
  end

  def suggested_emoji_key(description)
    ThemeEmojiSelector.new(description).key
  end
end
