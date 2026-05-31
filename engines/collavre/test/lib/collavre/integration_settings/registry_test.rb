# frozen_string_literal: true

require "test_helper"

module Collavre
  module IntegrationSettings
    class RegistryTest < ActiveSupport::TestCase
      setup do
        # Snapshot boot-time registrations (e.g. Slack engine) so we can
        # restore them in teardown without polluting other tests in the
        # same process.
        @registry_snapshot = Registry.instance.instance_variable_get(:@definitions).dup
        Registry.instance.instance_variable_set(:@definitions, {})
      end

      teardown do
        Registry.instance.instance_variable_set(:@definitions, @registry_snapshot || {})
      end

      test "registers a key with defaults" do
        Registry.instance.register(:slack_client_id, category: "slack")
        d = Registry.instance.find(:slack_client_id)
        assert_equal "slack",            d.category
        assert_equal true,               d.sensitive
        assert_equal false,              d.requires_restart
        assert_equal "SLACK_CLIENT_ID",  d.env_var
      end

      test "groups by category" do
        Registry.instance.register(:slack_client_id, category: "slack")
        Registry.instance.register(:google_client_id, category: "google_oauth")
        assert_equal %w[slack google_oauth].sort, Registry.instance.by_category.keys.sort
      end
    end
  end
end
