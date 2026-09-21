require "test_helper"
require "open3"

class CreativeImporterLoadingTest < ActiveSupport::TestCase
  test "rejects invalid uploads before the PPT importer has been loaded" do
    script = <<~'SCRIPT'
      require "active_support/all"
      abort "Zip was already loaded" if defined?(Zip)
      abort "Nokogiri was already loaded" if defined?(Nokogiri)

      module Collavre
        autoload :PptGeometry, File.expand_path("engines/collavre/app/services/collavre/ppt_geometry.rb")
        autoload :PptArchive, File.expand_path("engines/collavre/app/services/collavre/ppt_archive.rb")
        autoload :PptInheritance, File.expand_path("engines/collavre/app/services/collavre/ppt_inheritance.rb")
        autoload :PptColors, File.expand_path("engines/collavre/app/services/collavre/ppt_colors.rb")
        autoload :PptParagraphs, File.expand_path("engines/collavre/app/services/collavre/ppt_paragraphs.rb")
        autoload :PptFormatting, File.expand_path("engines/collavre/app/services/collavre/ppt_formatting.rb")
        autoload :PptImporter, File.expand_path("engines/collavre/app/services/collavre/ppt_importer.rb")
      end
      require_relative "engines/collavre/app/services/collavre/creatives/importer"

      file_class = Struct.new(:original_filename, :content_type)
      [ [ "invalid.txt", "text/plain" ], [ "invalid.pptx", "text/plain" ] ].each do |name, mime|
        begin
          Collavre::Creatives::Importer.new(file: file_class.new(name, mime), user: nil).call
          abort "Accepted invalid upload: #{name}"
        rescue Collavre::Creatives::Importer::UnsupportedFile => error
          abort "Unexpected error: #{error.message}" unless error.message == "Invalid file type"
        end
      end
    SCRIPT

    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-rbundler/setup", "-e", script, chdir: Rails.root.to_s
    )
    assert status.success?, "Fresh-process validation failed:\n#{stdout}\n#{stderr}"
  end
end
