# frozen_string_literal: true

require "test_helper"

class ComplexityRatchetEagerLoadingTest < ActiveSupport::TestCase
  test "excludes the CI-only complexity ratchet directories from eager loading" do
    ignored_paths = Rails.autoloaders.main.instance_variable_get(:@ignored_paths)

    assert_includes ignored_paths, Rails.root.join("lib/complexity_ratchet").to_s
    assert_includes ignored_paths, Rails.root.join("lib/js_complexity").to_s
  end
end
