# frozen_string_literal: true

require "test_helper"
require "open3"
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
        assert_equal "npm install --save-exact pdfjs-dist@4.8.69", command
        assert_equal true, options[:abort_on_failure]
      }) { generator.invoke_all }
    end

    assert_file "script/build.cjs", /nodePaths: \[path\.join\(process\.cwd\(\), 'node_modules'\)\]/
  end

  test "installs an exact PDF.js dependency with Yarn in Yarn hosts" do
    File.write(File.join(destination_root, "yarn.lock"), "")
    generator = self.class.generator_class.new([], {}, destination_root: destination_root)
    generator.stub(:run, ->(command, **options) {
      assert_equal "yarn add --exact pdfjs-dist@4.8.69", command
      assert_equal true, options[:abort_on_failure]
    }) { generator.install_pdf_dependency }
  end

  [ false, true ].each do |yarn_host|
    test "shows matching build instructions for #{yarn_host ? 'Yarn' : 'npm'} hosts" do
      File.write(File.join(destination_root, "yarn.lock"), "") if yarn_host
      generator = self.class.generator_class.new([], {}, destination_root: destination_root)
      messages = []
      generator.stub(:say, ->(message, *) { messages << message }) { generator.show_post_install }

      command = yarn_host ? "yarn build" : "npm run build"
      assert_includes messages, "Run '#{command}' to build assets."
      if yarn_host
        assert_includes messages, "Yarn requires nodeLinker: node-modules; Plug'n'Play is not supported."
      end
    end
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
        assert_equal "npm install --save-exact pdfjs-dist@4.8.69", command
        assert_equal true, options[:abort_on_failure]
      }) { generator.invoke_all }
    end

    assert_file "script/build.cjs", /nodePaths: \[require\('path'\)\.join\(process\.cwd\(\), 'node_modules'\)\]/
  end
  [ "bundle: true,", "bundle: true", "bundle: true\n" ].each do |bundle_property|
    test "updates configured dependency resolution with #{bundle_property.inspect}" do
      FileUtils.mkdir_p(File.join(destination_root, "script"))
      File.write(File.join(destination_root, "script/build.cjs"), "// collavre\nconst config = { #{bundle_property} };\n")
      generator = self.class.generator_class.new([], {}, destination_root: destination_root)
      Rails.stub(:root, Pathname.new(destination_root)) do
        2.times { generator.install_build_script }
      end

      content = File.read(File.join(destination_root, "script/build.cjs"))
      assert_equal 1, content.scan("nodePaths:").size
      script = File.join(destination_root, "script/build.cjs")
      File.write(script, "#{content}\nconsole.log(JSON.stringify(config.nodePaths));")
      output, status = Open3.capture2e("node", script, chdir: destination_root)
      assert status.success?, output
      assert_equal [ File.join(destination_root, "node_modules") ], JSON.parse(output)
    end
  end
  [ "nodePaths", '"nodePaths"', "'nodePaths'" ].each do |key|
    test "preserves custom #{key} and adds the host path only once" do
      FileUtils.mkdir_p(File.join(destination_root, "script"))
      script = File.join(destination_root, "script/build.cjs")
      File.write(script, <<~JS)
        // collavre
        const config = { bundle: true, #{key}: ['/custom/modules', '/other/modules'] };
      JS
      generator = self.class.generator_class.new([], {}, destination_root: destination_root)
      Rails.stub(:root, Pathname.new(destination_root)) do
        2.times { generator.install_build_script }
      end

      File.write(script, "#{File.read(script)}\nconsole.log(JSON.stringify(config.nodePaths));")
      output, status = Open3.capture2e("node", script, chdir: destination_root)
      assert status.success?, output
      assert_equal [ File.join(destination_root, "node_modules"), "/custom/modules", "/other/modules" ], JSON.parse(output)
    end
  end

  test "reports dynamic node paths instead of silently skipping the host path" do
    FileUtils.mkdir_p(File.join(destination_root, "script"))
    script = File.join(destination_root, "script/build.cjs")
    original = "// collavre\nconst config = { bundle: true, nodePaths: customPaths };"
    File.write(script, original)
    generator = self.class.generator_class.new([], {}, destination_root: destination_root)
    Rails.stub(:root, Pathname.new(destination_root)) do
      error = assert_raises(Thor::Error) { generator.install_build_script }
      assert_includes error.message, "Cannot update dynamic nodePaths"
    end
    assert_equal original, File.read(script)
  end
  test "reports unmatched host path insertion without changing a configured script" do
    FileUtils.mkdir_p(File.join(destination_root, "script"))
    script = File.join(destination_root, "script/build.cjs")
    original = "// collavre\nconst config = { \"bundle\": true };"
    File.write(script, original)
    generator = self.class.generator_class.new([], {}, destination_root: destination_root)
    Rails.stub(:root, Pathname.new(destination_root)) do
      error = assert_raises(Thor::Error) { generator.install_build_script }
      assert_includes error.message, "Add require('path').join(process.cwd(), 'node_modules') to nodePaths"
      assert_includes error.message, "rerun the generator"
    end
    assert_equal original, File.read(script)
  end
end
