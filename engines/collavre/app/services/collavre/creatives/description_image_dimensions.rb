# frozen_string_literal: true

module Collavre
  module Creatives
    class DescriptionImageDimensions
      BLOB_PATH = %r{\A(?:https?://[^/]+)?/(?:public-assets/blobs|rails/active_storage/blobs/(?:proxy|redirect))/([^/?#]+)/}

      def initialize(creatives, variation_id:)
        @descriptions = creatives.index_with { |creative| creative.effective_description(variation_id) }
        @sources = @descriptions.filter_map do |creative, html|
          [ creative, creative.origin || creative ] if html.match?(/<img\b/i)
        end.to_h
        preload_files
      end

      def html_for(creative)
        html = @descriptions.fetch(creative)
        source = @sources[creative]
        return html unless source

        dimensions = source.files_blobs.filter_map do |blob|
          width, height = blob.metadata.values_at("width", "height")
          [ blob.signed_id, [ width, height ] ] if width.to_i.positive? && height.to_i.positive?
        end.to_h
        return html if dimensions.empty?

        fragment = Nokogiri::HTML5.fragment(html)
        fragment.css("img").each { |image| apply_dimensions(image, dimensions) }
        fragment.to_html
      end

      private

      def preload_files
        return if @sources.empty?

        ActiveRecord::Associations::Preloader.new(records: @sources.values, associations: :files_blobs).call
      end

      def apply_dimensions(image, dimensions)
        return if image["width"] || image["height"]

        size = dimensions[image["src"].to_s[BLOB_PATH, 1]]
        return unless size

        image["width"], image["height"] = size
      end
    end
  end
end
