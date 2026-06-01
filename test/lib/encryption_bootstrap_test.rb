# frozen_string_literal: true

require "test_helper"

class EncryptionBootstrapTest < ActiveSupport::TestCase
  # Helper must populate fallback encryption keys when missing, so boot-time
  # DB readers (storage.yml / environments/*.rb) can decrypt admin-saved
  # integration_settings rows BEFORE the encryption initializer runs.

  FakeEncryptionConfig = Struct.new(
    :primary_key, :deterministic_key, :key_derivation_salt,
    :support_unencrypted_data, :extend_queries
  )

  class FakeApp
    def initialize(secret:, primary: nil, deterministic: nil, salt: nil)
      @secret = secret
      @encryption_config = FakeEncryptionConfig.new(primary, deterministic, salt, nil, nil)
    end

    attr_reader :secret_key_base
    def secret_key_base = @secret

    def config
      @config ||= OpenStruct.new(active_record: OpenStruct.new(encryption: @encryption_config))
    end

    def encryption_config = @encryption_config
  end

  test "populates fallback keys when all are blank" do
    app = FakeApp.new(secret: "x" * 64)
    EncryptionBootstrap.ensure_keys!(app)
    cfg = app.encryption_config
    assert cfg.primary_key.present?
    assert cfg.deterministic_key.present?
    assert_equal "active_record_encryption_salt", cfg.key_derivation_salt
  end

  test "is idempotent when keys already populated" do
    app = FakeApp.new(secret: "x" * 64, primary: "P", deterministic: "D", salt: "S")
    EncryptionBootstrap.ensure_keys!(app)
    cfg = app.encryption_config
    assert_equal "P", cfg.primary_key
    assert_equal "D", cfg.deterministic_key
    assert_equal "S", cfg.key_derivation_salt
  end

  test "fills only missing keys" do
    app = FakeApp.new(secret: "x" * 64, primary: "P")
    EncryptionBootstrap.ensure_keys!(app)
    cfg = app.encryption_config
    assert_equal "P", cfg.primary_key
    assert cfg.deterministic_key.present?
    assert_equal "active_record_encryption_salt", cfg.key_derivation_salt
  end

  test "no-op when secret_key_base is blank" do
    app = FakeApp.new(secret: nil)
    EncryptionBootstrap.ensure_keys!(app)
    cfg = app.encryption_config
    assert_nil cfg.primary_key
    assert_nil cfg.deterministic_key
    assert_nil cfg.key_derivation_salt
  end

  test "enables support_unencrypted_data and extend_queries even when keys already populated" do
    # Codex round 10 P2: read-side options must run BEFORE the
    # `return if ... present?` early return so plaintext / previous-key
    # integration_settings rows are still readable from boot-time callers.
    app = FakeApp.new(secret: "x" * 64, primary: "P", deterministic: "D", salt: "S")
    EncryptionBootstrap.ensure_keys!(app)
    cfg = app.encryption_config
    assert_equal true, cfg.support_unencrypted_data
    assert_equal true, cfg.extend_queries
  end

  test "enables support_unencrypted_data and extend_queries when secret is blank" do
    app = FakeApp.new(secret: nil)
    EncryptionBootstrap.ensure_keys!(app)
    cfg = app.encryption_config
    assert_equal true, cfg.support_unencrypted_data
    assert_equal true, cfg.extend_queries
  end

  test "derived keys are deterministic for the same secret" do
    app1 = FakeApp.new(secret: "x" * 64)
    app2 = FakeApp.new(secret: "x" * 64)
    EncryptionBootstrap.ensure_keys!(app1)
    EncryptionBootstrap.ensure_keys!(app2)
    assert_equal app1.encryption_config.primary_key, app2.encryption_config.primary_key
    assert_equal app1.encryption_config.deterministic_key, app2.encryption_config.deterministic_key
  end
end
