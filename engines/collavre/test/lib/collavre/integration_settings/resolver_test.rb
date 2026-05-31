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
        Registry.instance.register(
          :app_brand_name,
          category: "branding",
          sensitive: false,
          env_var: "APP_BRAND_NAME",
          default: "default-brand"
        )
        Rails.cache.clear
        IntegrationSetting.delete_all
      end

      teardown do
        Registry.instance.instance_variable_set(:@definitions, @registry_snapshot || {})
        ENV.delete("SLACK_CLIENT_ID")
        ENV.delete("APP_BRAND_NAME")
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

      test "non-sensitive key is cached on second read" do
        IntegrationSetting.create!(key: "app_brand_name", value: "first", category: "branding")
        assert_equal "first", Resolver.get(:app_brand_name)

        # Bypass callbacks so cache is not cleared
        IntegrationSetting.where(key: "app_brand_name").delete_all
        Rails.cache.write(
          IntegrationSetting.cache_key_for(:app_brand_name),
          "cached-value",
          expires_in: 5.minutes
        )
        assert_equal "cached-value", Resolver.get(:app_brand_name)
      end

      test "sensitive key bypasses Rails.cache to avoid persisting plaintext" do
        # Pre-poison the cache with a value that would only be returned if cache was consulted.
        Rails.cache.write(
          IntegrationSetting.cache_key_for(:slack_client_id),
          "cached-poison",
          expires_in: 5.minutes
        )
        IntegrationSetting.create!(key: "slack_client_id", value: "fresh-db", category: "slack")
        assert_equal "fresh-db", Resolver.get(:slack_client_id)
      end

      test "sensitive key resolution does not write to Rails.cache" do
        IntegrationSetting.create!(key: "slack_client_id", value: "secret-val", category: "slack")
        Rails.cache.clear
        Resolver.get(:slack_client_id)
        assert_nil Rails.cache.read(IntegrationSetting.cache_key_for(:slack_client_id))
      end
    end
  end
end
