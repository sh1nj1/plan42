require "open-uri"
require "nokogiri"
require "uri"

class LinkPreviewFetcher
  USER_AGENT = "Plan42LinkPreview/1.0".freeze
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 5
  MAX_BYTES = 200_000
  HTML_CONTENT_TYPES = [ "text/html", "application/xhtml+xml" ].freeze
  REQUEST_OPTIONS = {
    "User-Agent" => USER_AGENT,
    "Accept" => "text/html,application/xhtml+xml"
  }.freeze

  def self.fetch(url)
    new(url).fetch
  end

  def initialize(url, io_opener: URI, logger: Rails.logger)
    @url = url
    @io_opener = io_opener
    @logger = logger
  end

  def fetch
    return {} unless valid_http_url?

    html, base_uri = read_html
    return {} if html.blank?

    document = Nokogiri::HTML(html)
    build_metadata(document, base_uri)
  rescue StandardError => e
    @logger&.warn("Link preview fetch failed for #{@url}: #{e.class} #{e.message}")
    {}
  end

  private

  def valid_http_url?
    uri = URI.parse(@url)
    %w[http https].include?(uri.scheme)
  rescue URI::InvalidURIError
    false
  end

  def read_html
    html = nil
    base_uri = nil
    options = REQUEST_OPTIONS.merge(read_timeout: READ_TIMEOUT, open_timeout: OPEN_TIMEOUT)
    @io_opener.open(@url, options) do |io|
      content_type = io.respond_to?(:content_type) ? io.content_type : nil
      if content_type && HTML_CONTENT_TYPES.none? { |type| content_type.include?(type) }
        return [ nil, nil ]
      end
      base_uri = io.respond_to?(:base_uri) ? io.base_uri : URI.parse(@url)
      html = io.read(MAX_BYTES)
    end
    [ html, base_uri ]
  rescue OpenURI::HTTPError, SocketError, IOError, SystemCallError, URI::InvalidURIError => e
    @logger&.info("Link preview fetch skipped for #{@url}: #{e.class} #{e.message}")
    [ nil, nil ]
  end

  def build_metadata(document, base_uri)
    title = extract_title(document)
    description = extract_description(document)
    image_url = extract_image(document, base_uri)
    site_name = extract_site_name(document)

    metadata = {}
    metadata[:title] = title if title.present?
    metadata[:description] = description if description.present?
    metadata[:image_url] = image_url if image_url.present?
    metadata[:site_name] = site_name if site_name.present?
    metadata
  end

  def extract_title(document)
    [
      [ "property", "og:title" ],
      [ "name", "og:title" ],
      [ "name", "twitter:title" ],
      [ "name", "title" ]
    ].each do |attr, value|
      node = document.at_css(%(meta[#{attr}="#{value}"]))
      content = node&.[]("content")
      return normalize_text(content) if content.present?
    end
    title_tag = document.at_css("title")&.text
    normalize_text(title_tag)
  end

  def extract_description(document)
    [
      [ "property", "og:description" ],
      [ "name", "og:description" ],
      [ "name", "description" ],
      [ "name", "twitter:description" ]
    ].each do |attr, value|
      node = document.at_css(%(meta[#{attr}="#{value}"]))
      content = node&.[]("content")
      return normalize_text(content) if content.present?
    end
    nil
  end

  def extract_site_name(document)
    node = document.at_css('meta[property="og:site_name"]')
    normalize_text(node&.[]("content"))
  end

  def extract_image(document, base_uri)
    [
      [ "property", "og:image" ],
      [ "name", "og:image" ],
      [ "name", "twitter:image" ],
      [ "property", "og:image:url" ]
    ].each do |attr, value|
      node = document.at_css(%(meta[#{attr}="#{value}"]))
      url = node&.[]("content")
      next if url.blank?

      resolved = resolve_url(url, base_uri)
      return resolved if resolved.present?
    end
    nil
  end

  def resolve_url(url, base_uri)
    uri = URI.parse(url)
    if uri.scheme.blank? && base_uri
      URI.join(base_uri.to_s, url).to_s
    else
      uri.to_s
    end
  rescue URI::InvalidURIError
    nil
  end

  def normalize_text(text)
    return if text.blank?

    text.to_s.gsub(/\s+/, " ").strip
  end
end
