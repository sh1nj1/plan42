module Collavre
module Creatives
  class Importer
    class Error < StandardError; end
    class UnsupportedFile < Error; end

    MARKDOWN_MIME_TYPES = %w[text/markdown text/x-markdown application/octet-stream].freeze
    PPTX_MIME_TYPES = %w[
      application/vnd.openxmlformats-officedocument.presentationml.presentation
      application/octet-stream
    ].freeze

    def initialize(file:, user:, parent: nil)
      @file = file
      @user = user
      @parent = parent
    end

    def call
      raise Error, "File required" if file.blank?

      case extension
      when ".md"
        raise UnsupportedFile, "Invalid file type" unless MARKDOWN_MIME_TYPES.include?(mime_type)

        content = read_file_content
        MarkdownImporter.import(content, parent: parent, user: user, create_root: true)
      when ".pptx"
        raise UnsupportedFile, "Invalid file type" unless PPTX_MIME_TYPES.include?(mime_type)

        PptImporter.import(file.tempfile, parent: parent, user: user, create_root: true, filename: file.original_filename)
      else
        raise UnsupportedFile, "Invalid file type"
      end
    end

    private

    attr_reader :file, :user, :parent

    def extension
      File.extname(file.original_filename.to_s).downcase
    end

    def mime_type
      file.content_type.presence || Rack::Mime.mime_type(File.extname(file.original_filename.to_s))
    end

    def read_file_content
      file.rewind
      file.read.to_s.force_encoding("UTF-8")
    end
  end
end
end
