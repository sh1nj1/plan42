module Collavre
  require "open-uri"
  require "nokogiri"
  require "uri"
  require "ipaddr"
  require "resolv"

  class LinkPreviewFetcher
    USER_AGENT = "Plan42LinkPreview/1.0".freeze
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 5
    MAX_BYTES = 200_000
    MAX_REDIRECTS = 3
    HTML_CONTENT_TYPES = [ "text/html", "application/xhtml+xml" ].freeze
    REQUEST_OPTIONS = {
      "User-Agent" => USER_AGENT,
      "Accept" => "text/html,application/xhtml+xml"
    }.freeze
    DISALLOWED_IPV4_RANGES = [
      IPAddr.new("0.0.0.0/8"),
      IPAddr.new("100.64.0.0/10"),
      IPAddr.new("192.0.0.0/24"),
      IPAddr.new("198.18.0.0/15"),
      IPAddr.new("224.0.0.0/4"),
      IPAddr.new("240.0.0.0/4")
    ].freeze
    DISALLOWED_IPV6_RANGES = [
      IPAddr.new("::/128"),
      IPAddr.new("ff00::/8")
    ].freeze

    def self.fetch(url)
      new(url).fetch
    end

    def initialize(url, io_opener: URI, logger: Rails.logger)
      @url = url
      @io_opener = io_opener
      @logger = logger
    end

    def fetch
      uri = safe_http_uri
      return {} unless uri

      html, base_uri = read_html(uri)
      return {} if html.blank?

      document = Nokogiri::HTML(html)
      build_metadata(document, base_uri)
    rescue StandardError => e
      @logger&.warn("Link preview fetch failed for #{@url}: #{e.class} #{e.message}")
      {}
    end

    private

    def read_html(uri, redirect_limit = MAX_REDIRECTS)
      html = nil
      base_uri = nil
      options = REQUEST_OPTIONS.merge(read_timeout: READ_TIMEOUT, open_timeout: OPEN_TIMEOUT, redirect: false)
      @io_opener.open(uri.to_s, options) do |io|
        content_type = io.respond_to?(:content_type) ? io.content_type : nil
        if content_type && HTML_CONTENT_TYPES.none? { |type| content_type.include?(type) }
          return [ nil, nil ]
        end
        base_uri = io.respond_to?(:base_uri) ? io.base_uri : uri
        html = io.read(MAX_BYTES)
      end
      [ html, base_uri ]
    rescue OpenURI::HTTPRedirect => e
      return [ nil, nil ] if redirect_limit <= 0

      redirected_uri = safe_redirect_uri(uri, e.uri)
      return [ nil, nil ] unless redirected_uri

      read_html(redirected_uri, redirect_limit - 1)
    rescue OpenURI::HTTPError, SocketError, IOError, SystemCallError, URI::InvalidURIError => e
      @logger&.info("Link preview fetch skipped for #{@url}: #{e.class} #{e.message}")
      [ nil, nil ]
    end

    def safe_http_uri
      uri = parse_http_uri(@url)
      return unless uri
      return unless allowed_destination?(uri)

      uri
    end

    def safe_redirect_uri(current_uri, redirected)
      new_uri = normalize_redirect_uri(current_uri, redirected)
      return unless new_uri
      return unless allowed_destination?(new_uri)

      new_uri
    end

    def normalize_redirect_uri(current_uri, redirected)
      target_uri = redirected.is_a?(URI) ? redirected : URI.parse(redirected.to_s)
      target_uri = current_uri.merge(target_uri) if target_uri.relative?
      return unless %w[http https].include?(target_uri.scheme)

      target_uri
    rescue URI::InvalidURIError
      nil
    end

    def parse_http_uri(url)
      uri = URI.parse(url)
      return unless %w[http https].include?(uri.scheme)
      return unless uri.hostname && !uri.hostname.empty?

      uri
    rescue URI::InvalidURIError
      nil
    end

    def allowed_destination?(uri)
      host = uri.hostname
      return false if host.nil? || host.empty?

      addresses = resolve_addresses(host)
      return false if addresses.empty?
      return false if addresses.any? { |address| unsafe_ip?(address) }

      true
    end

    def resolve_addresses(host)
      Resolv.getaddresses(host).uniq
    rescue Resolv::ResolvError, SocketError, ArgumentError
      []
    end

    def unsafe_ip?(address)
      ip = IPAddr.new(address)
      ip = ip.native if ip.ipv4_mapped?

      return true if ip.loopback? || ip.link_local? || ip.private?

      ranges = ip.ipv4? ? DISALLOWED_IPV4_RANGES : DISALLOWED_IPV6_RANGES
      ranges.any? { |range| range.include?(ip) }
    rescue IPAddr::InvalidAddressError
      true
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
end
