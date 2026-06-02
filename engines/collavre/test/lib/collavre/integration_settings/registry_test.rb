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
        assert_equal :string,            d.input_type
        assert_equal true,               d.admin_visible
      end

      test "registers a key with input_type and admin_visible overrides" do
        Registry.instance.register(
          :firebase_service_account_json,
          category: "fcm",
          input_type: :textarea
        )
        Registry.instance.register(
          :google_application_credentials,
          category: "fcm",
          admin_visible: false
        )
        json_def = Registry.instance.find(:firebase_service_account_json)
        adc_def  = Registry.instance.find(:google_application_credentials)
        assert_equal :textarea, json_def.input_type
        assert_equal true,      json_def.admin_visible
        assert_equal false,     adc_def.admin_visible
      end

      test "groups by category" do
        Registry.instance.register(:slack_client_id, category: "slack")
        Registry.instance.register(:google_client_id, category: "google_oauth")
        assert_equal %w[slack google_oauth].sort, Registry.instance.by_category.keys.sort
      end
    end
  end
end
