# frozen_string_literal: true

require "test_helper"

module Collavre
  module IntegrationSettings
    # Boot-time consumers (initializers, mailers) call
    # `Collavre::IntegrationSettings.fetch` rather than `Resolver.get` directly
    # so a missing DB / unloaded model degrades gracefully to ENV without
    # raising. These tests cover that fallback behavior.
    class FetchTest < ActiveSupport::TestCase
      setup do
        @registry_snapshot = Registry.instance.instance_variable_get(:@definitions).dup
        Registry.instance.instance_variable_set(:@definitions, {})
        Registry.instance.register(
          :default_mailer_from,
          category: "mail",
          sensitive: false,
          env_var: "DEFAULT_MAILER_FROM",
          default: nil
        )
        ENV.delete("DEFAULT_MAILER_FROM")
        Rails.cache.clear
        IntegrationSetting.delete_all
      end

      teardown do
        Registry.instance.instance_variable_set(:@definitions, @registry_snapshot || {})
        ENV.delete("DEFAULT_MAILER_FROM")
        Rails.cache.clear
      end

      test "returns Resolver value when registered key has DB row" do
        IntegrationSetting.create!(key: "default_mailer_from", value: "db@example.com", category: "mail")
        assert_equal "db@example.com", Collavre::IntegrationSettings.fetch(:default_mailer_from)
      end

      test "returns ENV when no DB row and key is registered" do
        ENV["DEFAULT_MAILER_FROM"] = "env@example.com"
        assert_equal "env@example.com", Collavre::IntegrationSettings.fetch(:default_mailer_from)
      end

      test "unknown key returns nil instead of raising" do
        assert_nil Collavre::IntegrationSettings.fetch(:not_registered)
      end

      test "default kwarg returned when value blank" do
        assert_equal "fallback", Collavre::IntegrationSettings.fetch(:default_mailer_from, default: "fallback")
      end

      test "default kwarg used for unknown key" do
        assert_equal "fallback", Collavre::IntegrationSettings.fetch(:not_registered, default: "fallback")
      end

      test "Resolver errors caused by missing DB fall back to ENV" do
        ENV["DEFAULT_MAILER_FROM"] = "env-fallback@example.com"
        Resolver.stub(:get, ->(_k) { raise ActiveRecord::NoDatabaseError, "db down" }) do
          assert_equal "env-fallback@example.com",
                       Collavre::IntegrationSettings.fetch(:default_mailer_from)
        end
      end

      test "boot_safe: true falls back to ENV when encryption raises" do
        # AWS keys are consumed during `:load_environment_config`, which can
        # run before the host app's encryption initializer wires up keys. Boot
        # callers (storage.yml, config/environments/*.rb) opt in with
        # boot_safe: true so the row's decryption error doesn't crash boot.
        ENV["DEFAULT_MAILER_FROM"] = "env-after-encryption-error@example.com"
        Resolver.stub(:get, ->(_k) { raise ActiveRecord::Encryption::Errors::Configuration, "no key" }) do
          assert_equal "env-after-encryption-error@example.com",
                       Collavre::IntegrationSettings.fetch(:default_mailer_from, boot_safe: true)
        end
      end

      test "default (runtime) raises on encryption error so secret keys can't silently turn blank" do
        # Runtime callers like ApplicationController's CloudFront origin check
        # MUST see decryption failures — treating the secret as blank would
        # silently disable the origin verification.
        Resolver.stub(:get, ->(_k) { raise ActiveRecord::Encryption::Errors::Configuration, "no key" }) do
          assert_raises(ActiveRecord::Encryption::Errors::Configuration) do
            Collavre::IntegrationSettings.fetch(:origin_shared_secret)
          end
        end
      end

      test "non-encryption StandardError still bubbles up even under boot_safe" do
        # Encryption errors are the only ones explicitly rescued under
        # boot_safe; other StandardError subclasses must still propagate so
        # genuine bugs aren't masked.
        Resolver.stub(:get, ->(_k) { raise RuntimeError, "unexpected" }) do
          assert_raises(RuntimeError) do
            Collavre::IntegrationSettings.fetch(:default_mailer_from, boot_safe: true)
          end
        end
      end
    end
  end
end
