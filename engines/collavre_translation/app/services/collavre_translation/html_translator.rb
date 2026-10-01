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

      separator = "\nCOLLAVRE_TOKEN_999999\n"
      result = Translator.call(texts.join(separator), locale, **options).split(separator, -1)
      raise ArgumentError, "Translation changed text segments" unless result.length == texts.length

      texts.zip(result).map { |original, translated| { original: original, translated: translated } }.to_json
    end
  end
end
