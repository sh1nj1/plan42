module Creatives
  class Importer
    class Error < StandardError; end
    class UnsupportedFile < Error; end

    MARKDOWN_MIME_TYPES = %w[text/markdown text/x-markdown application/octet-stream].freeze
    PPT_MIME_TYPES = %w[
      application/vnd.ms-powerpoint
      application/vnd.openxmlformats-officedocument.presentationml.presentation
    ].freeze

    def initialize(file:, user:, parent: nil)
      @file = file
      @user = user
      @parent = parent
    end

    def call
      raise Error, "File required" if file.blank?

      case mime_type
      when *MARKDOWN_MIME_TYPES
        content = read_file_content
        MarkdownImporter.import(content, parent: parent, user: user, create_root: true)
      when *PPT_MIME_TYPES
        PptImporter.import(file.tempfile, parent: parent, user: user, create_root: true, filename: file.original_filename)
      else
        raise UnsupportedFile, "Invalid file type"
      end
    end

    private

    attr_reader :file, :user, :parent

    def mime_type
      file.content_type.presence || Rack::Mime.mime_type(File.extname(file.original_filename.to_s))
    end

    def read_file_content
      file.rewind
      file.read.to_s.force_encoding("UTF-8")
    end
  end
end
