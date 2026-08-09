require "test_helper"
require "generators/collavre/install/install_generator"

class Collavre::InstallGeneratorTest < ActiveSupport::TestCase
  test "documents the shared feature card stylesheet in every installation path" do
    generator = Collavre::Generators::InstallGenerator.new
    output, = capture_io { generator.show_post_install }

    assert_includes output, "@import 'collavre/feature_cards';"
    assert_includes Rails.root.join("engines/collavre/docs/installation.md").read,
                    '@import "collavre/feature_cards";'
    assert_includes Rails.root.join("engines/collavre/README.md").read,
                    '<%= stylesheet_link_tag "collavre/feature_cards" %>'
  end
end
