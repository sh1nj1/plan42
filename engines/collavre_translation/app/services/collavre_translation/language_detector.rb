require "cld3"

module CollavreTranslation
  class LanguageDetector
    def self.detect(content)
      prose = ProtectedContent.new(content).masked.gsub(/COLLAVRE_TOKEN_\d+/, "")
      return if prose.scan(/\p{L}/).length < 20

      result = CLD3::NNetLanguageIdentifier.new(0, 10_000).find_language(prose)
      result.language.to_s if result&.reliable? && result.probability >= 0.8
    end
  end
end
