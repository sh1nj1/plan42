module CollavreTranslation
  # Structural tokens are restored locally instead of trusting the model to copy them.
  class ProtectedContent
    PATTERN = /COLLAVRE_TOKEN_\d+|```[^\n]*\n.*?```|~~~[^\n]*\n.*?~~~|`+[^`\n]*`+|https?:\/\/[^\s<>)]*|@[^@:\n]{1,255}:|@\[[^\]]+\]|@[\p{L}\p{N}_.-]+:?|!?\[[^\]]*\]\([^)]*\)|<[^>]+>/m
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
