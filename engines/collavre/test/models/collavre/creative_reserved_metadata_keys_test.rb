# frozen_string_literal: true

require "test_helper"

# Tests for Collavre::Creative.reserved_metadata_keys registry.
# Vendor-neutral: uses a dummy key "x", no engine names.
class Collavre::CreativeReservedMetadataKeysTest < ActiveSupport::TestCase
  teardown do
    # Remove ONLY the dummy key these tests register. Never wipe or replace the
    # whole registry — engine keys (e.g. "linear") are registered once at boot
    # via `to_prepare` and would not be re-registered, causing intermittent
    # false-red/green in the combined randomized suite.
    Collavre::Creative.registered_reserved_metadata_keys.delete("x")
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

  test "registering and removing the dummy key preserves engine-registered keys" do
    # Simulate an engine key registered once at boot (never re-registered).
    Collavre::Creative.register_reserved_metadata_key("boot_only")
    Collavre::Creative.register_reserved_metadata_key("x")

    # The teardown removes only "x"; assert boot_only survives that mutation.
    Collavre::Creative.registered_reserved_metadata_keys.delete("x")
    assert_includes Collavre::Creative.reserved_metadata_keys, "boot_only"
    refute_includes Collavre::Creative.reserved_metadata_keys, "x"
  ensure
    Collavre::Creative.registered_reserved_metadata_keys.delete("boot_only")
  end
end
