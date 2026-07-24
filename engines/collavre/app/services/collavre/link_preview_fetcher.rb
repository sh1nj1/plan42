module Collavre
  require "net/http"
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

    # Minimal HTTP result the fetcher reasons about. `body` is only populated for
    # successful (2xx) responses; redirects carry a `location` instead.
    Response = Struct.new(:code, :content_type, :body, :location, keyword_init: true)

    def self.fetch(url)
      new(url).fetch
    end

    def initialize(url, http_client: nil, logger: Rails.logger)
      @url = url
      @http_client = http_client || PinnedHttpClient.new
      @logger = logger
    end

    def fetch
      uri = parse_http_uri(@url)
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
      # Resolve+validate the host ONCE per hop and pin the request to that exact
      # IP. This closes the DNS-rebinding TOCTOU gap: a hostname that validates
      # as public here can no longer be re-resolved to a private/metadata IP at
      # connect time, because the connection targets the pinned address (with the
      # original hostname preserved for Host/SNI).
      addresses = safe_addresses(uri)
      return [ nil, nil ] if addresses.empty?

      response = fetch_via_pinned_addresses(uri, addresses)
      return [ nil, nil ] unless response

      if redirect?(response.code)
        return [ nil, nil ] if redirect_limit <= 0

        redirected_uri = normalize_redirect_uri(uri, response.location)
        return [ nil, nil ] unless redirected_uri

        # Recurse so the new host is resolved+validated+pinned from scratch;
        # never follow a hop to an internal address.
        return read_html(redirected_uri, redirect_limit - 1)
      end

      return [ nil, nil ] unless success?(response.code)

      content_type = response.content_type
      if content_type && HTML_CONTENT_TYPES.none? { |type| content_type.include?(type) }
        return [ nil, nil ]
      end

      [ response.body, uri ]
    rescue SocketError, IOError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout,
           OpenSSL::SSL::SSLError, URI::InvalidURIError => e
      @logger&.info("Link preview fetch skipped for #{@url}: #{e.class} #{e.message}")
      [ nil, nil ]
    end

    def redirect?(code)
      code.to_i.between?(300, 399)
    end

    def success?(code)
      code.to_i.between?(200, 299)
    end

    def normalize_redirect_uri(current_uri, redirected)
      return if redirected.blank?

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

    # Resolve the host, reject if it maps to ANY unsafe address, and return every
    # validated public IP to pin against. Rejecting when any resolved address is
    # unsafe (not just the one we pick) keeps defense-in-depth against
    # split-horizon DNS returning a mix of public and private records. Returning
    # all safe addresses lets the caller fall back to the next one when the first
    # is unreachable (e.g. an AAAA record with no IPv6 egress).
    def safe_addresses(uri)
      host = uri.hostname
      return [] if host.nil? || host.empty?

      addresses = resolve_addresses(host)
      return [] if addresses.empty?
      return [] if addresses.any? { |address| unsafe_ip?(address) }

      addresses
    end

    # Try each pre-validated address in turn, pinning the connection to it, and
    # return the first response we can actually open. Connection-level failures
    # fall through to the next candidate; if none connect, the caller treats it
    # as an empty preview. Every address here already passed safe_addresses, so
    # falling back never targets an unsafe IP.
    def fetch_via_pinned_addresses(uri, addresses)
      last_error = nil
      addresses.each do |address|
        return @http_client.get(
          uri,
          ip: address,
          headers: REQUEST_OPTIONS,
          open_timeout: OPEN_TIMEOUT,
          read_timeout: READ_TIMEOUT,
          max_bytes: MAX_BYTES
        )
      rescue SocketError, IOError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout,
             OpenSSL::SSL::SSLError => e
        last_error = e
      end
      @logger&.info("Link preview fetch skipped for #{@url}: #{last_error.class} #{last_error.message}") if last_error
      nil
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

    # Performs a single (non-redirect-following) GET against a pre-resolved IP
    # while keeping the original hostname for the Host header and TLS SNI/cert
    # verification. Net::HTTP#ipaddr= pins the socket to `ip`, so no second DNS
    # lookup happens between validation and connect. Enforces the caller's open/
    # read timeouts and byte cap.
    class PinnedHttpClient
      def get(uri, ip:, headers:, open_timeout:, read_timeout:, max_bytes:)
        # Pass an explicit nil proxy: Net::HTTP.new defaults p_addr to :ENV, so a
        # set http_proxy/HTTP_PROXY would route through the proxy, which resolves
        # the hostname itself and defeats `http.ipaddr = ip` pinning — reopening
        # the DNS-rebinding/SSRF gap. nil forces a direct, pinned connection.
        http = Net::HTTP.new(uri.hostname, uri.port, nil)
        http.use_ssl = uri.scheme == "https"
        http.ipaddr = ip
        http.open_timeout = open_timeout
        http.read_timeout = read_timeout

        request = Net::HTTP::Get.new(uri, headers)
        response_struct = nil

        http.start do |conn|
          conn.request(request) do |response|
            body = read_capped_body(response, max_bytes)
            response_struct = Response.new(
              code: response.code.to_i,
              content_type: response.content_type,
              body: body,
              location: response["location"]
            )
          end
        end

        response_struct
      ensure
        http&.finish if http&.started?
      end

      private

      def read_capped_body(response, max_bytes)
        return nil unless response.is_a?(Net::HTTPSuccess)

        body = +""
        response.read_body do |chunk|
          body << chunk
          break if body.bytesize >= max_bytes
        end
        body.byteslice(0, max_bytes)
      end
    end
  end
end
