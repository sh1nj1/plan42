# frozen_string_literal: true

require_relative "../../test_helper"

# Tests for Collavre::Creative.reserved_metadata_keys registry.
# Vendor-neutral: uses a dummy key "x", no engine names.
class Collavre::CreativeReservedMetadataKeysTest < ActiveSupport::TestCase
  setup do
    # Reset between tests to avoid cross-test pollution
    Collavre::Creative.instance_variable_set(:@registered_reserved_metadata_keys, nil)
  end

  teardown do
    # Clean up any registered dummy keys after each test
    Collavre::Creative.instance_variable_set(:@registered_reserved_metadata_keys, nil)
  end

  test "reserved_metadata_keys includes base keys by default" do
    keys = Collavre::Creative.reserved_metadata_keys
    assert_includes keys, "markdown_source"
    assert_includes keys, "content_type"
    assert_includes keys, "editor"
  end

  test "register_reserved_metadata_key adds key to reserved_metadata_keys" do
    Collavre::Creative.register_reserved_metadata_key("x")
    assert_includes Collavre::Creative.reserved_metadata_keys, "x"
  end

  test "register_reserved_metadata_key is idempotent" do
    Collavre::Creative.register_reserved_metadata_key("x")
    Collavre::Creative.register_reserved_metadata_key("x")
    count = Collavre::Creative.reserved_metadata_keys.count("x")
    assert_equal 1, count
  end

  test "reserved_metadata_keys returns a frozen array" do
    keys = Collavre::Creative.reserved_metadata_keys
    assert keys.frozen?
  end

  test "base keys are always present even after registering additional keys" do
    Collavre::Creative.register_reserved_metadata_key("x")
    keys = Collavre::Creative.reserved_metadata_keys
    assert_includes keys, "markdown_source"
    assert_includes keys, "content_type"
    assert_includes keys, "editor"
    assert_includes keys, "x"
  end
end
