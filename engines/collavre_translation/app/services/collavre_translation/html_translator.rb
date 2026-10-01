module CollavreTranslation
  # Translate only prose. Attributes, protected subtrees and markup never reach the provider.
  class HtmlTranslator
    PROTECTED = "pre, code, script, style, textarea, .mention, [data-mention], [data-lexical-mention], [contenteditable], [data-ppt-slide]"

    def self.texts(html)
      fragment = Nokogiri::HTML.fragment(html)
      fragment.css(PROTECTED).each(&:remove)
      fragment.xpath(".//text()").map(&:text).reject(&:blank?).uniq
    end

    def self.call(html, locale, **options)
      texts = texts(html)
      return "[]" if texts.empty?

      separator = segment_separator(texts)
      result = Translator.call(texts.map(&:strip).join(separator), locale, **options)
        .split(/\s*#{Regexp.escape(separator.strip)}\s*/, -1)
      raise ArgumentError, "Translation changed text segments" unless result.length == texts.length

      texts.zip(result).map do |original, translated|
        { original: original, translated: preserve_whitespace(original, translated) }
      end.to_json
    end

    def self.preserve_whitespace(original, translated)
      "#{original[/\A\s*/]}#{translated.strip}#{original[/\s*\z/]}"
    end
    private_class_method :preserve_whitespace

    # Restored source literals must never be mistaken for inserted boundaries.
    def self.segment_separator(texts)
      index = 999999
      index += 1 while texts.any? { |text| text.include?("COLLAVRE_TOKEN_#{index}_END") }
      "\nCOLLAVRE_TOKEN_#{index}_END\n"
    end
    private_class_method :segment_separator
  end
end
