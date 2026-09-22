require "test_helper"
require "open3"

class CreativeImporterLoadingTest < ActiveSupport::TestCase
  test "rejects invalid uploads before the PPT importer has been loaded" do
    script = <<~'SCRIPT'
      require "active_support/all"
      abort "Zip was already loaded" if defined?(Zip)
      abort "Nokogiri was already loaded" if defined?(Nokogiri)

      module Collavre
        Dir.glob(File.expand_path("engines/collavre/app/services/collavre/ppt_*.rb")).each do |path|
          autoload File.basename(path, ".rb").camelize.to_sym, path
        end
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
