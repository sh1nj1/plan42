# frozen_string_literal: true

require "test_helper"

class TestEnvironmentTest < ActiveSupport::TestCase
  test "resolves assets from current source instead of a public precompile manifest" do
    manifest_path = Rails.application.config.assets.manifest_path

    assert_match %r{\A#{Regexp.escape(Rails.root.to_s)}/tmp/test-assets/\d+/\.manifest\.json\z}, manifest_path.to_s
    refute_predicate manifest_path, :exist?
    assert_instance_of Propshaft::Resolver::Dynamic, Rails.application.assets.resolver
  end
end
