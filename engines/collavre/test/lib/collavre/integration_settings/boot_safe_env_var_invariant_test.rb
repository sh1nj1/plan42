# frozen_string_literal: true

require "test_helper"

module Collavre
  module IntegrationSettings
    # Regression guard for the production PWA/FCM push outage (creative #14282).
    #
    # `IntegrationSettings.fetch(..., boot_safe: true)` — used by boot-time
    # initializers such as `config/initializers/fcm.rb` — can only fall back to
    # `ENV[key.upcase]` when the DB/registry is not yet reachable. The runtime
    # `Resolver`, by contrast, reads `ENV[definition.env_var]`. When a key is
    # registered with a custom `env_var` that differs from `key.upcase`, boot and
    # runtime read DIFFERENT environment variables: a value present at runtime is
    # absent at boot. In production this left the FCM WIF credential built without
    # a service-account impersonation URL, so every push silently failed with
    # `Unauthorized` at send time while the admin UI still showed the value set.
    #
    # Until `fetch`'s boot-safe path is taught to honor `env_var`, every
    # registered key MUST keep `env_var == key.upcase` so boot-time and runtime
    # resolution agree on the same ENV variable.
    class BootSafeEnvVarInvariantTest < ActiveSupport::TestCase
      test "every registered key's env_var matches key.upcase so boot-safe fetch and runtime Resolver read the same ENV var" do
        mismatches = Registry.instance.all.filter_map do |definition|
          expected = definition.key.to_s.upcase
          next if definition.env_var == expected

          "#{definition.key}: env_var=#{definition.env_var.inspect} (expected #{expected.inspect})"
        end

        assert_empty mismatches,
          "These registered keys use a custom env_var diverging from key.upcase, which splits boot-safe " \
          "fetch (reads ENV[key.upcase]) from runtime Resolver (reads ENV[env_var]):\n#{mismatches.join("\n")}"
      end
    end
  end
end
