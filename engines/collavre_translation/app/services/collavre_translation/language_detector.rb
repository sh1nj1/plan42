require "cld3"

module CollavreTranslation
  class LanguageDetector
    def self.detect(content)
      prose = ProtectedContent.new(content).masked.gsub(/COLLAVRE_TOKEN_\d+_END/, "")
      letters = prose.scan(/\p{L}/).join
      return "ko" if letters.match?(/\A\p{Hangul}+\z/)
      return if letters.length < 20

      result = CLD3::NNetLanguageIdentifier.new(0, 10_000).find_language(prose)
      result.language.to_s if result&.reliable? && result.probability >= 0.8
    end
  end
end
