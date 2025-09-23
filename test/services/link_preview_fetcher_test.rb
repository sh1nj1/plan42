require "test_helper"
require "stringio"
require "open-uri"

class LinkPreviewFetcherTest < ActiveSupport::TestCase
  class NullLogger
    def warn(*) end
    def info(*) end
  end

  class FakeOpener
    attr_reader :calls

    def initialize(*responses)
      @responses = responses
      @calls = []
    end

    def open(url, options)
      @calls << [ url, options ]
      action, value = @responses.shift
      raise "No response configured" unless action

      case action
      when :yield
        raise "Expected block" unless block_given?
        yield value
      when :raise
        raise value
      else
        raise "Unknown action: #{action.inspect}"
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

  def build_io(body, content_type: "text/html", base_url: "https://example.com/article")
    base_uri = URI.parse(base_url)
    StringIO.new(body).tap do |io|
      io.define_singleton_method(:content_type) { content_type }
      io.define_singleton_method(:base_uri) { base_uri }
      io.define_singleton_method(:read) do |*args|
        body.dup
      end
    end
  end

  def stub_addresses(fetcher, mapping)
    resolve = lambda do |host|
      mapping.fetch(host, [])
    end
    fetcher.stub(:resolve_addresses, resolve) { yield }
  end

  test "extracts metadata from html head" do
    url = "https://example.com/article"
    io = build_io(HTML, base_url: url)
    opener = FakeOpener.new([ :yield, io ])
    fetcher = LinkPreviewFetcher.new(url, io_opener: opener, logger: NullLogger.new)

    metadata = stub_addresses(fetcher, URI.parse(url).hostname => [ "93.184.216.34" ]) do
      fetcher.fetch
    end

    assert_equal "Example Title", metadata[:title]
    assert_equal "An example description.", metadata[:description]
    assert_equal "https://example.com/image.png", metadata[:image_url]
    assert_equal "Example", metadata[:site_name]

    assert_equal 1, opener.calls.size
    _called_url, options = opener.calls.first
    assert_equal false, options[:redirect]
    assert_equal LinkPreviewFetcher::USER_AGENT, options["User-Agent"]
  end

  test "falls back to the title tag when og:title missing" do
    url = "https://example.com/article"
    io = build_io("<html><head><title>Fallback Title</title></head><body></body></html>", base_url: url)
    opener = FakeOpener.new([ :yield, io ])
    fetcher = LinkPreviewFetcher.new(url, io_opener: opener, logger: NullLogger.new)

    metadata = stub_addresses(fetcher, URI.parse(url).hostname => [ "93.184.216.34" ]) do
      fetcher.fetch
    end

    assert_equal "Fallback Title", metadata[:title]
  end

  test "returns empty metadata when content type not html" do
    url = "https://example.com/file"
    io = build_io("binary", content_type: "image/png", base_url: url)
    opener = FakeOpener.new([ :yield, io ])
    fetcher = LinkPreviewFetcher.new(url, io_opener: opener, logger: NullLogger.new)

    metadata = stub_addresses(fetcher, URI.parse(url).hostname => [ "93.184.216.34" ]) do
      fetcher.fetch
    end

    assert_equal({}, metadata)
  end

  test "handles network errors gracefully" do
    url = "https://example.com/error"
    opener = FakeOpener.new([ :raise, OpenURI::HTTPError.new("500", nil) ])
    fetcher = LinkPreviewFetcher.new(url, io_opener: opener, logger: NullLogger.new)

    metadata = stub_addresses(fetcher, URI.parse(url).hostname => [ "93.184.216.34" ]) do
      fetcher.fetch
    end

    assert_equal({}, metadata)
  end

  test "returns empty metadata when host resolves to private address" do
    url = "https://example.com/private"
    opener = FakeOpener.new
    fetcher = LinkPreviewFetcher.new(url, io_opener: opener, logger: NullLogger.new)

    metadata = stub_addresses(fetcher, URI.parse(url).hostname => [ "10.0.0.5" ]) do
      fetcher.fetch
    end

    assert_equal({}, metadata)
    assert_empty opener.calls
  end

  test "returns empty metadata for loopback ip urls" do
    url = "http://127.0.0.1/secret"
    opener = FakeOpener.new
    fetcher = LinkPreviewFetcher.new(url, io_opener: opener, logger: NullLogger.new)

    metadata = stub_addresses(fetcher, URI.parse(url).hostname => [ "127.0.0.1" ]) do
      fetcher.fetch
    end

    assert_equal({}, metadata)
    assert_empty opener.calls
  end

  test "follows redirects when destination allowed" do
    url = "https://example.com/article"
    redirect_uri = URI.parse("https://www.example.com/article")
    io = build_io(HTML, base_url: redirect_uri.to_s)
    redirect_error = OpenURI::HTTPRedirect.new("301", StringIO.new, redirect_uri)
    opener = FakeOpener.new([ :raise, redirect_error ], [ :yield, io ])
    fetcher = LinkPreviewFetcher.new(url, io_opener: opener, logger: NullLogger.new)

    mapping = {
      URI.parse(url).hostname => [ "93.184.216.34" ],
      redirect_uri.hostname => [ "93.184.216.35" ]
    }

    metadata = stub_addresses(fetcher, mapping) do
      fetcher.fetch
    end

    assert_equal "Example Title", metadata[:title]
    assert_equal "https://www.example.com/image.png", metadata[:image_url]
    assert_equal 2, opener.calls.size
    assert_equal url, opener.calls.first.first
    assert_equal redirect_uri.to_s, opener.calls.second.first
  end

  test "stops following redirects that resolve to private addresses" do
    url = "https://example.com/article"
    redirect_uri = URI.parse("https://internal.example/resource")
    redirect_error = OpenURI::HTTPRedirect.new("301", StringIO.new, redirect_uri)
    opener = FakeOpener.new([ :raise, redirect_error ])
    fetcher = LinkPreviewFetcher.new(url, io_opener: opener, logger: NullLogger.new)

    mapping = {
      URI.parse(url).hostname => [ "93.184.216.34" ],
      redirect_uri.hostname => [ "10.0.0.8" ]
    }

    metadata = stub_addresses(fetcher, mapping) do
      fetcher.fetch
    end

    assert_equal({}, metadata)
    assert_equal 1, opener.calls.size
  end
end
