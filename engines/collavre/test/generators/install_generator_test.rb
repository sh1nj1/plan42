# frozen_string_literal: true

require "test_helper"
require "rails/generators"
require "rails/generators/test_case"
require_relative "../../lib/generators/collavre/install/install_generator"

class CollavreInstallGeneratorTest < Rails::Generators::TestCase
  tests Collavre::Generators::InstallGenerator
  destination File.expand_path("../../../../tmp/install_generator", __dir__)
  setup :prepare_destination

  test "installs PDF.js and generates host dependency resolution" do
    generator = self.class.generator_class.new([], {}, destination_root: destination_root)
    Rails.stub(:root, Pathname.new(destination_root)) do
      generator.stub(:run, ->(command, **options) {
        assert_equal "npm install pdfjs-dist@4.8.69", command
        assert_equal true, options[:abort_on_failure]
      }) { generator.invoke_all }
    end

    assert_file "script/build.cjs", /nodePaths: \[path\.join\(process\.cwd\(\), 'node_modules'\)\]/
  end

  test "adds host dependency resolution to an existing build script" do
    FileUtils.mkdir_p(File.join(destination_root, "script"))
    File.write(File.join(destination_root, "script/build.cjs"), <<~JS)
      const path = require('path');
      const entryPoints = {};
      if (Object.keys(entryPoints).length === 0) process.exit(0);
      const config = { bundle: true, };
    JS
    generator = self.class.generator_class.new([], {}, destination_root: destination_root)
    Rails.stub(:root, Pathname.new(destination_root)) do
      generator.stub(:run, ->(command, **options) {
        assert_equal "npm install pdfjs-dist@4.8.69", command
        assert_equal true, options[:abort_on_failure]
      }) { generator.invoke_all }
    end

    assert_file "script/build.cjs", /nodePaths: \[path\.join\(process\.cwd\(\), 'node_modules'\)\]/
  end
  test "updates dependency resolution when Collavre is already configured" do
    FileUtils.mkdir_p(File.join(destination_root, "script"))
    File.write(File.join(destination_root, "script/build.cjs"), "// collavre\nconst config = { bundle: true, };\n")
    generator = self.class.generator_class.new([], {}, destination_root: destination_root)
    Rails.stub(:root, Pathname.new(destination_root)) do
      2.times { generator.install_build_script }
    end

    content = File.read(File.join(destination_root, "script/build.cjs"))
    assert_equal 1, content.scan("nodePaths:").size
    assert_includes content, "nodePaths: [path.join(process.cwd(), 'node_modules')]"
  end
end
