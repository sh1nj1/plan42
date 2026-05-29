# frozen_string_literal: true

require_relative "../../test_helper"

module CollavreSlack
  class ConfigurationTest < ActiveSupport::TestCase
    KEYS = {
      client_id:      { reg: :slack_client_id,      env: "SLACK_CLIENT_ID",      sensitive: false },
      client_secret:  { reg: :slack_client_secret,  env: "SLACK_CLIENT_SECRET",  sensitive: true },
      signing_secret: { reg: :slack_signing_secret, env: "SLACK_SIGNING_SECRET", sensitive: true },
      redirect_uri:   { reg: :slack_redirect_uri,   env: "SLACK_REDIRECT_URI",   sensitive: false }
    }.freeze

    setup do
      # Reset module-level memoized config so each test reads fresh ivar state.
      CollavreSlack.instance_variable_set(:@config, nil)
      Rails.cache.clear
      Collavre::IntegrationSetting.delete_all
      KEYS.each_value { |meta| ENV.delete(meta[:env]) }
    end

    teardown do
      CollavreSlack.instance_variable_set(:@config, nil)
      Rails.cache.clear
      Collavre::IntegrationSetting.delete_all
      KEYS.each_value { |meta| ENV.delete(meta[:env]) }
    end

    test "engine registers all four Slack OAuth keys with the registry" do
      KEYS.each do |_attr, meta|
        definition = Collavre::IntegrationSettings::Registry.instance.find(meta[:reg])
        assert_not_nil definition, "expected #{meta[:reg]} to be registered"
        assert_equal "slack", definition.category
        assert_equal meta[:sensitive], definition.sensitive
        assert_equal true, definition.requires_restart
        assert_equal meta[:env], definition.env_var
      end
    end

    test "getters resolve DB value over ENV (DB wins)" do
      KEYS.each do |attr, meta|
        Collavre::IntegrationSetting.create!(
          key: meta[:reg].to_s, value: "db-#{attr}", category: "slack"
        )
        ENV[meta[:env]] = "env-#{attr}"
      end

      KEYS.each_key do |attr|
        assert_equal "db-#{attr}", CollavreSlack::Configuration.new.public_send(attr),
          "expected DB value for #{attr}"
      end
    end

    test "getters fall back to ENV when no DB row exists" do
      KEYS.each do |attr, meta|
        ENV[meta[:env]] = "env-#{attr}"
      end

      KEYS.each_key do |attr|
        assert_equal "env-#{attr}", CollavreSlack::Configuration.new.public_send(attr),
          "expected ENV value for #{attr}"
      end
    end

    test "getters fall back to ENV when integration_settings table is missing" do
      KEYS.each do |_attr, meta|
        ENV[meta[:env]] = "boot-#{meta[:env]}"
      end

      Collavre::IntegrationSetting.stub :find_by, ->(*) { raise ActiveRecord::StatementInvalid, "no such table" } do
        KEYS.each do |attr, meta|
          assert_equal "boot-#{meta[:env]}", CollavreSlack::Configuration.new.public_send(attr),
            "expected ENV fallback for #{attr} when DB unavailable"
        end
      end
    end

    test "getters fall back to ENV when Resolver constant is undefined (USE_COLLAVRE_GEM with older core)" do
      KEYS.each do |_attr, meta|
        ENV[meta[:env]] = "gem-#{meta[:env]}"
      end

      # Simulate the `Collavre::IntegrationSettings::Resolver` namespace not being
      # loaded (e.g. installed `collavre` gem predates this feature).
      resolver_const = Collavre::IntegrationSettings.send(:remove_const, :Resolver)
      begin
        KEYS.each do |attr, meta|
          assert_equal "gem-#{meta[:env]}", CollavreSlack::Configuration.new.public_send(attr),
            "expected ENV fallback for #{attr} when Resolver constant missing"
        end
      ensure
        Collavre::IntegrationSettings.const_set(:Resolver, resolver_const)
      end
    end

    test "writers still override resolver lookups (test affordance)" do
      ENV["SLACK_SIGNING_SECRET"] = "env-signing"
      config = CollavreSlack::Configuration.new
      assert_equal "env-signing", config.signing_secret

      config.signing_secret = "explicit-override"
      assert_equal "explicit-override", config.signing_secret
    end

    test "scopes still come from ENV (out of scope for resolver swap)" do
      ENV["SLACK_SCOPES"] = "chat:write"
      assert_equal "chat:write", CollavreSlack::Configuration.new.scopes
    ensure
      ENV.delete("SLACK_SCOPES")
    end
  end
end
