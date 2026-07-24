module CollavreGithub
  module MarkdownSync
    class ContentProcessor
      IMAGE_EXTENSIONS = %w[.png .jpg .jpeg .gif .svg .webp .ico .bmp .tiff .avif].freeze

      def initialize(client:, repo:, branch:, path_to_creative_map:)
        @client = client
        @repo = repo
        @branch = branch
        @path_to_creative_map = path_to_creative_map
        @image_cache = {}
      end

      # Returns [processed_content, array_of_blobs]
      def process(markdown_content, file_path)
        content = markdown_content.dup
        blobs = []
        dir = File.dirname(file_path)

        content = content.gsub(/(!?)\[([^\]]*)\]\(([^)]+)\)/) do |match|
          prefix = Regexp.last_match(1)
          label = Regexp.last_match(2)
          url = Regexp.last_match(3)

          next match if absolute_url?(url) || anchor_only?(url)

          if prefix == "!"
            process_image(match, label, url, dir, blobs)
          else
            process_link(match, label, url, dir)
          end
        end

        [ content, blobs ]
      end

      private

      def process_image(match, alt, url, dir, blobs)
        url_path = strip_fragment_and_query(url)
        resolved = resolve_path(dir, url_path)

        blob = download_and_upload(resolved)
        return match unless blob

        blobs << blob
        blob_url = Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true)
        "![#{alt}](#{blob_url})"
      end

      def process_link(match, label, url, dir)
        url_path, fragment = url.split("#", 2)
        url_path = strip_query(url_path)
        resolved = resolve_path(dir, url_path)

        creative = @path_to_creative_map[resolved]
        return match unless creative

        link = "/creatives/#{creative.id}"
        link += "##{fragment}" if fragment.present?
        "[#{label}](#{link})"
      end

      def download_and_upload(resolved_path)
        return @image_cache[resolved_path] if @image_cache.key?(resolved_path)

        raw = @client.file_content(@repo, resolved_path, ref: @branch)
        unless raw.present?
          @image_cache[resolved_path] = nil
          return nil
        end

        filename = File.basename(resolved_path)
        ext = File.extname(filename).downcase
        content_type = Rack::Mime.mime_type(ext, "application/octet-stream")

        blob = ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(raw),
          filename: filename,
          content_type: content_type
        )
        @image_cache[resolved_path] = blob
        blob
      rescue StandardError => e
        Rails.logger.warn("[MarkdownSync] Image download failed for #{resolved_path}: #{e.message}")
        @image_cache[resolved_path] = nil
        nil
      end

      def resolve_path(dir, relative)
        clean = relative.to_s.strip
        return clean if clean.empty?
        Pathname.new(File.join(dir, clean)).cleanpath.to_s
      end

      def absolute_url?(url)
        url.match?(%r{\A(https?://|//|mailto:)})
      end

      def anchor_only?(url)
        url.start_with?("#")
      end

      def strip_fragment_and_query(url)
        url.split("#").first.split("?").first
      end

      def strip_query(url)
        url.split("?").first
      end
    end
  end
end
