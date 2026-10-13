module CollavreNotion
  class NotionRateLimitError < NotionError
    attr_reader :retry_after

    def initialize(message = "Rate limit exceeded", retry_after: 1)
      super(message)
      @retry_after = [ retry_after.to_f, 1 ].max
    end
  end
end
