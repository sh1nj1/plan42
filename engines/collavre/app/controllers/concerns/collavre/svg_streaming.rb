# frozen_string_literal: true

require "delegate"

module Collavre
  # Preserve Rails streaming/range handling while displaying SVG as an image.
  # Sandboxing also protects direct navigation to untrusted SVG documents.
  module SvgStreaming
    POLICY = "sandbox; default-src 'none'; style-src 'unsafe-inline'; img-src data:; frame-ancestors 'none'"

    class ImageBlob < SimpleDelegator
      def content_type_for_serving
        "image/svg+xml"
      end

      def forced_disposition_for_serving
        nil
      end
    end

    private

    def svg_image_blob(blob)
      return blob unless Rack::MediaType.type(blob.content_type) == "image/svg+xml"

      response.headers["Content-Security-Policy"] = POLICY
      response.headers["X-Content-Type-Options"] = "nosniff"
      ImageBlob.new(blob)
    end

    def send_blob_stream(blob, **options)
      super(svg_image_blob(blob), **options)
    end

    def send_blob_byte_range_data(blob, range_header, disposition: params[:disposition], **options)
      super(svg_image_blob(blob), range_header, disposition: disposition, **options)
    end
  end
end
