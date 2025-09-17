require "rails_helper"
require "open-uri"
require "stringio"

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

  def build_io(body, content_type: "text/html")
    StringIO.new(body).tap do |io|
      io.define_singleton_method(:content_type) { content_type }
      io.define_singleton_method(:base_uri) { URI(url) }
    end
  end

  it "extracts metadata from the HTML head" do
    io = build_io(html)
    expect(URI).to receive(:open).with(url, hash_including("User-Agent" => described_class::USER_AGENT)).and_yield(io)

    metadata = described_class.new(url, io_opener: URI, logger: logger).fetch

    expect(metadata[:title]).to eq("Example Title")
    expect(metadata[:description]).to eq("An example description.")
    expect(metadata[:image_url]).to eq("https://example.com/image.png")
    expect(metadata[:site_name]).to eq("Example")
  end

  it "falls back to the <title> tag when og:title is missing" do
    io = build_io("<html><head><title>Fallback Title</title></head><body></body></html>")
    expect(URI).to receive(:open).and_yield(io)

    metadata = described_class.new(url, io_opener: URI, logger: logger).fetch

    expect(metadata[:title]).to eq("Fallback Title")
  end

  it "returns an empty hash when the content type is not HTML" do
    io = build_io("binary data", content_type: "image/png")
    expect(URI).to receive(:open).and_yield(io)

    metadata = described_class.new(url, io_opener: URI, logger: logger).fetch

    expect(metadata).to eq({})
  end

  it "handles network errors gracefully" do
    expect(URI).to receive(:open).and_raise(OpenURI::HTTPError.new("500", nil))

    metadata = described_class.new(url, io_opener: URI, logger: logger).fetch

    expect(metadata).to eq({})
  end
end
