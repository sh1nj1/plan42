require "rails_helper"
require "open-uri"
require "stringio"
require "uri"

RSpec.describe LinkPreviewFetcher do
  let(:logger) { instance_double(Logger, warn: nil, info: nil) }
  let(:url) { "https://example.com/article" }
  let(:html) do
    <<~HTML
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
  end

  def build_io(body, content_type: "text/html", base_url: url)
    base_uri = URI.parse(base_url)

    StringIO.new(body).tap do |io|
      io.define_singleton_method(:content_type) { content_type }
      io.define_singleton_method(:base_uri) { base_uri }
    end
  end

  def stub_resolved_addresses(fetcher, mapping)
    allow(fetcher).to receive(:resolve_addresses) do |host|
      mapping.fetch(host, [])
    end
  end

  it "extracts metadata from the HTML head" do
    io = build_io(html)
    expect(URI).to receive(:open).with(url, hash_including("User-Agent" => described_class::USER_AGENT, redirect: false)).and_yield(io)

    fetcher = described_class.new(url, io_opener: URI, logger: logger)
    stub_resolved_addresses(fetcher, URI.parse(url).hostname => [ "93.184.216.34" ])
    metadata = fetcher.fetch

    expect(metadata[:title]).to eq("Example Title")
    expect(metadata[:description]).to eq("An example description.")
    expect(metadata[:image_url]).to eq("https://example.com/image.png")
    expect(metadata[:site_name]).to eq("Example")
  end

  it "falls back to the <title> tag when og:title is missing" do
    io = build_io("<html><head><title>Fallback Title</title></head><body></body></html>")
    expect(URI).to receive(:open).and_yield(io)

    fetcher = described_class.new(url, io_opener: URI, logger: logger)
    stub_resolved_addresses(fetcher, URI.parse(url).hostname => [ "93.184.216.34" ])
    metadata = fetcher.fetch

    expect(metadata[:title]).to eq("Fallback Title")
  end

  it "returns an empty hash when the content type is not HTML" do
    io = build_io("binary data", content_type: "image/png")
    expect(URI).to receive(:open).and_yield(io)

    fetcher = described_class.new(url, io_opener: URI, logger: logger)
    stub_resolved_addresses(fetcher, URI.parse(url).hostname => [ "93.184.216.34" ])
    metadata = fetcher.fetch

    expect(metadata).to eq({})
  end

  it "handles network errors gracefully" do
    expect(URI).to receive(:open).and_raise(OpenURI::HTTPError.new("500", nil))

    fetcher = described_class.new(url, io_opener: URI, logger: logger)
    stub_resolved_addresses(fetcher, URI.parse(url).hostname => [ "93.184.216.34" ])
    metadata = fetcher.fetch

    expect(metadata).to eq({})
  end

  it "returns an empty hash when the host resolves to a private address" do
    fetcher = described_class.new(url, io_opener: URI, logger: logger)
    stub_resolved_addresses(fetcher, URI.parse(url).hostname => [ "10.0.0.5" ])

    expect(URI).not_to receive(:open)

    metadata = fetcher.fetch

    expect(metadata).to eq({})
  end

  it "returns an empty hash for loopback IP URLs" do
    local_url = "http://127.0.0.1/secret"
    fetcher = described_class.new(local_url, io_opener: URI, logger: logger)
    stub_resolved_addresses(fetcher, URI.parse(local_url).hostname => [ "127.0.0.1" ])

    expect(URI).not_to receive(:open)

    metadata = fetcher.fetch

    expect(metadata).to eq({})
  end

  it "follows redirects when the destination is allowed" do
    redirect_uri = URI.parse("https://www.example.com/article")
    io = build_io(html, base_url: redirect_uri.to_s)
    opener = double("io_opener")
    redirect_error = OpenURI::HTTPRedirect.new("301", StringIO.new, redirect_uri)

    expect(opener).to receive(:open).with(url, hash_including(redirect: false)).ordered.and_raise(redirect_error)
    expect(opener).to receive(:open).with(redirect_uri.to_s, hash_including(redirect: false)).ordered.and_yield(io)

    fetcher = described_class.new(url, io_opener: opener, logger: logger)
    stub_resolved_addresses(fetcher, {
      URI.parse(url).hostname => [ "93.184.216.34" ],
      redirect_uri.hostname => [ "93.184.216.35" ]
    })

    metadata = fetcher.fetch

    expect(metadata[:title]).to eq("Example Title")
    expect(metadata[:image_url]).to eq("https://www.example.com/image.png")
  end

  it "stops following redirects that resolve to private addresses" do
    redirect_uri = URI.parse("https://internal.example/resource")
    opener = double("io_opener")
    redirect_error = OpenURI::HTTPRedirect.new("301", StringIO.new, redirect_uri)

    expect(opener).to receive(:open).with(url, hash_including(redirect: false)).and_raise(redirect_error)

    fetcher = described_class.new(url, io_opener: opener, logger: logger)
    stub_resolved_addresses(fetcher, {
      URI.parse(url).hostname => [ "93.184.216.34" ],
      redirect_uri.hostname => [ "10.0.0.8" ]
    })

    metadata = fetcher.fetch

    expect(metadata).to eq({})
  end
end
