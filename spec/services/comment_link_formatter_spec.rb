require "rails_helper"

RSpec.describe CommentLinkFormatter do
  describe "#format" do
    let(:logger) { instance_double(Logger, warn: nil) }

    it "replaces plain URLs with markdown links using fetched titles" do
      fetcher = ->(_url) { { title: "Example Domain" } }
      formatter = described_class.new("Check https://example.com", metadata_fetcher: fetcher, logger: logger)

      expect(formatter.format).to eq("Check [Example Domain](https://example.com)")
    end

    it "preserves trailing punctuation outside the link" do
      fetcher = ->(_url) { { title: "Example" } }
      formatter = described_class.new("Visit https://example.com.", metadata_fetcher: fetcher, logger: logger)

      expect(formatter.format).to eq("Visit [Example](https://example.com).")
    end

    it "does not alter existing markdown links" do
      fetcher = double("metadata fetcher")
      expect(fetcher).to receive(:call).once.and_return({ title: "Another" })

      content = "Already [Saved](https://example.com) and https://another.example"
      formatter = described_class.new(content, metadata_fetcher: fetcher, logger: logger)

      expect(formatter.format).to eq("Already [Saved](https://example.com) and [Another](https://another.example)")
    end

    it "returns original content when metadata is missing" do
      fetcher = ->(_url) { {} }
      formatter = described_class.new("https://example.com", metadata_fetcher: fetcher, logger: logger)

      expect(formatter.format).to eq("https://example.com")
    end

    it "swallows errors from the metadata fetcher" do
      fetcher = lambda do |_url|
        raise StandardError, "boom"
      end

      formatter = described_class.new("https://example.com", metadata_fetcher: fetcher, logger: logger)

      expect(formatter.format).to eq("https://example.com")
    end
  end
end
