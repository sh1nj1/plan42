# frozen_string_literal: true

require "test_helper"

module Collavre
  module IntegrationSettings
    class ResolverTest < ActiveSupport::TestCase
      setup do
        # Snapshot boot-time registrations (e.g. Slack engine) so other tests
        # in the same process don't lose their key definitions.
        @registry_snapshot = Registry.instance.instance_variable_get(:@definitions).dup
        Registry.instance.instance_variable_set(:@definitions, {})
        Registry.instance.register(
          :slack_client_id,
          category: "slack",
          env_var: "SLACK_CLIENT_ID",
          default: "default-id"
        )
        Rails.cache.clear
        IntegrationSetting.delete_all
      end

      teardown do
        Registry.instance.instance_variable_set(:@definitions, @registry_snapshot || {})
        ENV.delete("SLACK_CLIENT_ID")
        Rails.cache.clear
      end

      test "DB beats ENV" do
        IntegrationSetting.create!(key: "slack_client_id", value: "db-val", category: "slack")
        ENV["SLACK_CLIENT_ID"] = "env-val"
        assert_equal "db-val", Resolver.get(:slack_client_id)
        assert_equal :db,      Resolver.source_for(:slack_client_id)
      end

      test "ENV used when no DB row" do
        ENV["SLACK_CLIENT_ID"] = "env-val"
        assert_equal "env-val", Resolver.get(:slack_client_id)
        assert_equal :env,      Resolver.source_for(:slack_client_id)
      end

      test "default used when neither" do
        assert_equal "default-id", Resolver.get(:slack_client_id)
        assert_equal :default,     Resolver.source_for(:slack_client_id)
      end

      test "unknown key raises" do
        assert_raises(Resolver::UnknownKeyError) { Resolver.get(:nope) }
      end

      test "source_for returns :unknown for unknown key" do
        assert_equal :unknown, Resolver.source_for(:nope)
      end

      test "cache is hit on second read" do
        IntegrationSetting.create!(key: "slack_client_id", value: "first", category: "slack")
        assert_equal "first", Resolver.get(:slack_client_id)

        # Bypass callbacks so cache is not cleared
        IntegrationSetting.where(key: "slack_client_id").delete_all
        Rails.cache.write(
          IntegrationSetting.cache_key_for(:slack_client_id),
          "cached-value",
          expires_in: 5.minutes
        )
        assert_equal "cached-value", Resolver.get(:slack_client_id)
      end
    end
  end
end
