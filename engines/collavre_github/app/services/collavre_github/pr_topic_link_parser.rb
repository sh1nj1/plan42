module CollavreGithub
  class PrTopicLinkParser
    TOPIC_RE = %r{/creatives/\d+/topics/(\d+)}.freeze

    def self.call(body)
      return nil if body.blank?
      m = body.match(TOPIC_RE)
      m && m[1].to_i
    end
  end
end
