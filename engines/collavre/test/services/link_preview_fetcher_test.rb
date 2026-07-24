require "test_helper"

class LinkPreviewFetcherTest < ActiveSupport::TestCase
  Response = Collavre::LinkPreviewFetcher::Response

  class NullLogger
    def warn(*) end
    def info(*) end
  end

  # Records every request and its pinned IP, then returns the next queued
  # response (a Response struct) or raises the next queued error. Mirrors the
  # PinnedHttpClient#get contract.
  class FakeClient
    Call = Struct.new(:uri, :ip, keyword_init: true)

    attr_reader :calls

    def initialize(*responses)
      @responses = responses
      @calls = []
    end

    def get(uri, ip:, headers:, open_timeout:, read_timeout:, max_bytes:)
      @calls << Call.new(uri: uri, ip: ip)
      entry = @responses.shift
      raise "No response configured" unless entry

      kind, value = entry
      case kind
      when :response then value
      when :raise then raise value
      else raise "Unknown kind: #{kind.inspect}"
      end
    end
  end

  HTML = <<~HTML.freeze
    <html>
      <head>
        <meta property="og:title" content="Example Title" />
        <meta property="og:description" content="An example description." />
        <meta property="og:image" content="/image.png" />
        <meta property="og:site_name" content="Example" />
      </head>
      <body></body>
    </html>
  HTML

  def ok_response(body, content_type: "text/html")
    Response.new(code: 200, content_type: content_type, body: body, location: nil)
  end

  def redirect_response(location)
    Response.new(code: 301, content_type: nil, body: nil, location: location)
  end

  def stub_addresses(fetcher, mapping)
    resolve = lambda do |host|
      mapping.fetch(host, [])
    end
    fetcher.stub(:resolve_addresses, resolve) { yield }
  end

  test "extracts metadata from html head" do
    url = "https://example.com/article"
    client = FakeClient.new([ :response, ok_response(HTML) ])
    fetcher = Collavre::LinkPreviewFetcher.new(url, http_client: client, logger: NullLogger.new)

    metadata = stub_addresses(fetcher, URI.parse(url).hostname => [ "93.184.216.34" ]) do
      fetcher.fetch
    end

    assert_equal "Example Title", metadata[:title]
    assert_equal "An example description.", metadata[:description]
    assert_equal "https://example.com/image.png", metadata[:image_url]
    assert_equal "Example", metadata[:site_name]

    assert_equal 1, client.calls.size
    # Connection is pinned to the resolved IP, not re-resolved at connect time.
    assert_equal "93.184.216.34", client.calls.first.ip
    assert_equal url, client.calls.first.uri.to_s
  end

  test "falls back to the title tag when og:title missing" do
    url = "https://example.com/article"
    body = "<html><head><title>Fallback Title</title></head><body></body></html>"
    client = FakeClient.new([ :response, ok_response(body) ])
    fetcher = Collavre::LinkPreviewFetcher.new(url, http_client: client, logger: NullLogger.new)

    metadata = stub_addresses(fetcher, URI.parse(url).hostname => [ "93.184.216.34" ]) do
      fetcher.fetch
    end

    assert_equal "Fallback Title", metadata[:title]
  end

  test "returns empty metadata when content type not html" do
    url = "https://example.com/file"
    client = FakeClient.new([ :response, ok_response("binary", content_type: "image/png") ])
    fetcher = Collavre::LinkPreviewFetcher.new(url, http_client: client, logger: NullLogger.new)

    metadata = stub_addresses(fetcher, URI.parse(url).hostname => [ "93.184.216.34" ]) do
      fetcher.fetch
    end

    assert_equal({}, metadata)
  end

  test "handles network errors gracefully" do
    url = "https://example.com/error"
    client = FakeClient.new([ :raise, SocketError.new("boom") ])
    fetcher = Collavre::LinkPreviewFetcher.new(url, http_client: client, logger: NullLogger.new)

    metadata = stub_addresses(fetcher, URI.parse(url).hostname => [ "93.184.216.34" ]) do
      fetcher.fetch
    end

    assert_equal({}, metadata)
  end

  test "returns empty metadata when host resolves to private address" do
    url = "https://example.com/private"
    client = FakeClient.new
    fetcher = Collavre::LinkPreviewFetcher.new(url, http_client: client, logger: NullLogger.new)

    metadata = stub_addresses(fetcher, URI.parse(url).hostname => [ "10.0.0.5" ]) do
      fetcher.fetch
    end

    assert_equal({}, metadata)
    # Rejected before any connection is attempted.
    assert_empty client.calls
  end

  test "returns empty metadata for loopback ip urls" do
    url = "http://127.0.0.1/secret"
    client = FakeClient.new
    fetcher = Collavre::LinkPreviewFetcher.new(url, http_client: client, logger: NullLogger.new)

    metadata = stub_addresses(fetcher, URI.parse(url).hostname => [ "127.0.0.1" ]) do
      fetcher.fetch
    end

    assert_equal({}, metadata)
    assert_empty client.calls
  end

  test "follows redirects when destination allowed" do
    url = "https://example.com/article"
    redirect_uri = "https://www.example.com/article"
    client = FakeClient.new(
      [ :response, redirect_response(redirect_uri) ],
      [ :response, ok_response(HTML) ]
    )
    fetcher = Collavre::LinkPreviewFetcher.new(url, http_client: client, logger: NullLogger.new)

    mapping = {
      URI.parse(url).hostname => [ "93.184.216.34" ],
      URI.parse(redirect_uri).hostname => [ "93.184.216.35" ]
    }

    metadata = stub_addresses(fetcher, mapping) do
      fetcher.fetch
    end

    assert_equal "Example Title", metadata[:title]
    # Image resolves against the final (redirected) base URI.
    assert_equal "https://www.example.com/image.png", metadata[:image_url]
    assert_equal 2, client.calls.size
    assert_equal url, client.calls.first.uri.to_s
    assert_equal "93.184.216.34", client.calls.first.ip
    assert_equal redirect_uri, client.calls.second.uri.to_s
    # The redirect target is pinned to its own freshly-resolved IP.
    assert_equal "93.184.216.35", client.calls.second.ip
  end

  test "stops following redirects that resolve to private addresses" do
    url = "https://example.com/article"
    redirect_uri = "https://internal.example/resource"
    client = FakeClient.new([ :response, redirect_response(redirect_uri) ])
    fetcher = Collavre::LinkPreviewFetcher.new(url, http_client: client, logger: NullLogger.new)

    mapping = {
      URI.parse(url).hostname => [ "93.184.216.34" ],
      URI.parse(redirect_uri).hostname => [ "10.0.0.8" ]
    }

    metadata = stub_addresses(fetcher, mapping) do
      fetcher.fetch
    end

    assert_equal({}, metadata)
    # First hop connects; the private redirect target is rejected before connect.
    assert_equal 1, client.calls.size
  end

  test "falls back to the next safe address when the first is unreachable" do
    url = "https://example.com/dual-stack"
    # First (e.g. AAAA/no egress) address raises at connect; the second succeeds.
    client = FakeClient.new(
      [ :raise, SocketError.new("no route to host") ],
      [ :response, ok_response(HTML) ]
    )
    fetcher = Collavre::LinkPreviewFetcher.new(url, http_client: client, logger: NullLogger.new)

    metadata = stub_addresses(fetcher, URI.parse(url).hostname => [ "2606:2800:220:1:248:1893:25c8:1946", "93.184.216.34" ]) do
      fetcher.fetch
    end

    assert_equal "Example Title", metadata[:title]
    assert_equal 2, client.calls.size
    assert_equal "2606:2800:220:1:248:1893:25c8:1946", client.calls.first.ip
    assert_equal "93.184.216.34", client.calls.second.ip
  end

  test "rejects a host that resolves to a mix of public and private addresses" do
    url = "https://example.com/split-horizon"
    client = FakeClient.new
    fetcher = Collavre::LinkPreviewFetcher.new(url, http_client: client, logger: NullLogger.new)

    metadata = stub_addresses(fetcher, URI.parse(url).hostname => [ "93.184.216.34", "169.254.169.254" ]) do
      fetcher.fetch
    end

    assert_equal({}, metadata)
    assert_empty client.calls
  end
end
