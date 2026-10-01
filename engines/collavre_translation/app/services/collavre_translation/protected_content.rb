module CollavreTranslation
  # Structural tokens are restored locally instead of trusting the model to copy them.
  class ProtectedContent
    FENCES = /^ {0,3}(?<ticks>`{3,})[^`\n]*\n.*?(?:^ {0,3}\k<ticks>`*[ \t]*\r?$|\z)|^ {0,3}(?<tildes>~{3,})[^\n]*\n.*?(?:^ {0,3}\k<tildes>~*[ \t]*\r?$|\z)/m
    TOKENS = /COLLAVRE_TOKEN_\d+|`+[^`\n]*`+|https?:\/\/[^\s<>)]*|@[^@:\n]{1,255}:|@\[[^\]]+\]|@[\p{L}\p{N}_.-]+:?|!?\[[^\]]*\]\([^)]*\)|<[^>]+>/
    PATTERN = Regexp.union(FENCES, TOKENS)
    attr_reader :masked

    def initialize(content)
      @tokens = []
      @masked = content.to_s.gsub(PATTERN) do |token|
        @tokens << token
        "COLLAVRE_TOKEN_#{@tokens.length - 1}"
      end
    end

    def restore(result)
      expected = @tokens.each_index.map { |i| "COLLAVRE_TOKEN_#{i}" }
      actual = result.scan(/COLLAVRE_TOKEN_\d+/)
      raise ArgumentError, "Translation changed protected tokens" unless actual.sort == expected.sort

      result.gsub(/COLLAVRE_TOKEN_(\d+)/) { @tokens[Regexp.last_match(1).to_i] }
    end
  end
end
