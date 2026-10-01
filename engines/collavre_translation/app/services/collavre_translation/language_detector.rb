require "cld3"

module CollavreTranslation
  class LanguageDetector
    def self.translatable?(content)
      unprotected_prose(content).match?(/\p{L}/)
    end

    def self.unprotected_prose(content)
      ProtectedContent.new(content).masked.gsub(/COLLAVRE_TOKEN_\d+_END/, "")
    end
    private_class_method :unprotected_prose

    def self.detect(content)
      prose = unprotected_prose(content)
      letters = prose.scan(/\p{L}/).join
      return "ko" if letters.match?(/\A\p{Hangul}+\z/)
      return if letters.length < 20

      result = CLD3::NNetLanguageIdentifier.new(0, 10_000).find_language(prose)
      result.language.to_s if result&.reliable? && result.probability >= 0.8
    end
  end
end
