# frozen_string_literal: true

require "test_helper"

module Collavre
  module IntegrationSettings
    class RegistryTest < ActiveSupport::TestCase
      setup { Registry.instance.instance_variable_set(:@definitions, {}) }
      teardown { Registry.instance.instance_variable_set(:@definitions, {}) }

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
