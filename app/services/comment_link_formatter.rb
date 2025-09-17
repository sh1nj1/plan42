require "uri"

class CommentLinkFormatter
  URL_REGEX = URI::DEFAULT_PARSER.make_regexp(%w[http https])
  TRAILING_PUNCTUATION = ".,!?;:".freeze

  def initialize(content, metadata_fetcher: nil, logger: Rails.logger)
    @content = content.to_s
    @metadata_fetcher = metadata_fetcher || method(:default_fetch_metadata)
    @logger = logger
  end

  def format
    return @content if @content.blank?

    @content.gsub(URL_REGEX) do |match|
      match_data = Regexp.last_match
      url, trailing = strip_trailing_punctuation(match)
      next match if markdown_link?(match_data.pre_match)

      metadata = fetch_metadata(url)
      title = metadata[:title].presence
      next match if title.blank?

      "[#{title}](#{url})#{trailing}"
    end
  end

  private

  def strip_trailing_punctuation(url)
    trailing = ""
    while url.length.positive? && TRAILING_PUNCTUATION.include?(url[-1])
      trailing = url[-1] + trailing
      url = url[0...-1]
    end
    [ url, trailing ]
  end

  def markdown_link?(pre_match)
    return false unless pre_match
    pre_match =~ /\[[^\]]*\]\([^)]*$/
  end

  def fetch_metadata(url)
    @metadata_cache ||= {}
    return @metadata_cache[url] if @metadata_cache.key?(url)

    @metadata_cache[url] = @metadata_fetcher.call(url)
  rescue StandardError => e
    @logger&.warn("Failed to fetch link metadata for #{url}: #{e.class} #{e.message}")
    @metadata_cache[url] = {}
  end

  def default_fetch_metadata(url)
    LinkPreviewFetcher.fetch(url)
  end
end
