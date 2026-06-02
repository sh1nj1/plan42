# frozen_string_literal: true

require "test_helper"

module Collavre
  # The SES settings interceptor reads `aws_region`, `aws_ses_smtp_username`,
  # `aws_ses_smtp_password` from `IntegrationSettings` (DB > ENV) at send time
  # and mutates the message's SMTP delivery settings. These tests cover the
  # injection rules without actually sending mail.
  class SesSettingsInterceptorTest < ActiveSupport::TestCase
    setup do
      @registry_snapshot = Collavre::IntegrationSettings::Registry.instance
        .instance_variable_get(:@definitions).dup
      Collavre::IntegrationSettings::Registry.instance
        .instance_variable_set(:@definitions, {})
      registry = Collavre::IntegrationSettings::Registry.instance
      registry.register(:aws_region,               category: "aws", sensitive: false)
      registry.register(:aws_ses_smtp_username,    category: "aws", sensitive: true)
      registry.register(:aws_ses_smtp_password,    category: "aws", sensitive: true)

      %w[AWS_REGION AWS_SES_SMTP_USERNAME AWS_SES_SMTP_PASSWORD].each { |k| ENV.delete(k) }
      Rails.cache.clear
      Collavre::IntegrationSetting.delete_all
    end

    teardown do
      Collavre::IntegrationSettings::Registry.instance
        .instance_variable_set(:@definitions, @registry_snapshot || {})
      %w[AWS_REGION AWS_SES_SMTP_USERNAME AWS_SES_SMTP_PASSWORD].each { |k| ENV.delete(k) }
      Rails.cache.clear
    end

    test "injects DB values into SMTP settings" do
      Collavre::IntegrationSetting.create!(key: "aws_region", value: "us-east-1", category: "aws")
      Collavre::IntegrationSetting.create!(key: "aws_ses_smtp_username", value: "DB-USER", category: "aws")
      Collavre::IntegrationSetting.create!(key: "aws_ses_smtp_password", value: "DB-PASS", category: "aws")

      message = build_smtp_message(settings: { port: 587 })
      Collavre::SesSettingsInterceptor.delivering_email(message)

      assert_equal "email-smtp.us-east-1.amazonaws.com", message.delivery_method.settings[:address]
      assert_equal "DB-USER", message.delivery_method.settings[:user_name]
      assert_equal "DB-PASS", message.delivery_method.settings[:password]
    end

    test "DB value beats ENV" do
      ENV["AWS_SES_SMTP_USERNAME"] = "env-user"
      ENV["AWS_SES_SMTP_PASSWORD"] = "env-pass"
      Collavre::IntegrationSetting.create!(key: "aws_ses_smtp_username", value: "db-user", category: "aws")
      Collavre::IntegrationSetting.create!(key: "aws_ses_smtp_password", value: "db-pass", category: "aws")

      message = build_smtp_message(settings: { port: 587 })
      Collavre::SesSettingsInterceptor.delivering_email(message)

      assert_equal "db-user", message.delivery_method.settings[:user_name]
      assert_equal "db-pass", message.delivery_method.settings[:password]
    end

    test "falls back to ENV when no DB row" do
      ENV["AWS_REGION"] = "ap-northeast-2"
      ENV["AWS_SES_SMTP_USERNAME"] = "env-user"
      ENV["AWS_SES_SMTP_PASSWORD"] = "env-pass"

      message = build_smtp_message(settings: { port: 587 })
      Collavre::SesSettingsInterceptor.delivering_email(message)

      assert_equal "email-smtp.ap-northeast-2.amazonaws.com", message.delivery_method.settings[:address]
      assert_equal "env-user", message.delivery_method.settings[:user_name]
      assert_equal "env-pass", message.delivery_method.settings[:password]
    end

    test "leaves settings untouched when no DB/ENV/credentials values" do
      message = build_smtp_message(settings: { port: 587, address: "preset.example.com" })
      Collavre::SesSettingsInterceptor.delivering_email(message)

      assert_equal "preset.example.com", message.delivery_method.settings[:address]
      assert_nil message.delivery_method.settings[:user_name]
      assert_nil message.delivery_method.settings[:password]
    end

    test "skips half-configured SES credentials (username without password)" do
      Collavre::IntegrationSetting.create!(key: "aws_ses_smtp_username", value: "DB-USER", category: "aws")

      message = build_smtp_message(settings: { port: 587 })
      Collavre::SesSettingsInterceptor.delivering_email(message)

      assert_nil message.delivery_method.settings[:user_name]
      assert_nil message.delivery_method.settings[:password]
    end

    test "skips half-configured SES credentials (password without username)" do
      Collavre::IntegrationSetting.create!(key: "aws_ses_smtp_password", value: "DB-PASS", category: "aws")

      message = build_smtp_message(settings: { port: 587 })
      Collavre::SesSettingsInterceptor.delivering_email(message)

      assert_nil message.delivery_method.settings[:user_name]
      assert_nil message.delivery_method.settings[:password]
    end

    test "falls through to coherent ENV pair when only one DB half is set" do
      ENV["AWS_SES_SMTP_USERNAME"] = "env-user"
      ENV["AWS_SES_SMTP_PASSWORD"] = "env-pass"
      Collavre::IntegrationSetting.create!(key: "aws_ses_smtp_username", value: "db-user", category: "aws")

      message = build_smtp_message(settings: { port: 587 })
      Collavre::SesSettingsInterceptor.delivering_email(message)

      assert_equal "env-user", message.delivery_method.settings[:user_name]
      assert_equal "env-pass", message.delivery_method.settings[:password]
    end

    test "clears stale user_name/password when no coherent pair remains" do
      message = build_smtp_message(
        settings: { port: 587, user_name: "stale-user", password: "stale-pass" }
      )
      Collavre::SesSettingsInterceptor.delivering_email(message)

      assert_nil message.delivery_method.settings[:user_name]
      assert_nil message.delivery_method.settings[:password]
    end

    test "does not treat localhost SMTP relay as SES target" do
      # A host app running a real localhost SMTP relay (postfix on the
      # box, dev MailHog, etc.) must not have its `:user_name`/`:password`
      # wiped or address overwritten just because it left Mail's default
      # `"localhost"` address in place.
      ENV["AWS_REGION"] = "us-east-1"
      ENV["AWS_SES_SMTP_USERNAME"] = "env-user"
      ENV["AWS_SES_SMTP_PASSWORD"] = "env-pass"

      message = build_smtp_message(
        settings: {
          address:   "localhost",
          port:      25,
          user_name: "local-user",
          password:  "local-pass"
        }
      )
      Collavre::SesSettingsInterceptor.delivering_email(message)

      assert_equal "localhost",  message.delivery_method.settings[:address]
      assert_equal "local-user", message.delivery_method.settings[:user_name]
      assert_equal "local-pass", message.delivery_method.settings[:password]
    end

    test "passes through non-SES SMTP provider with credentials" do
      # Host app uses SendGrid (or any non-SES SMTP). Even with SES creds
      # configured, the interceptor must leave non-SES messages untouched.
      ENV["AWS_REGION"] = "us-east-1"
      ENV["AWS_SES_SMTP_USERNAME"] = "env-user"
      ENV["AWS_SES_SMTP_PASSWORD"] = "env-pass"

      message = build_smtp_message(
        settings: {
          address:   "smtp.sendgrid.net",
          port:      587,
          user_name: "sendgrid-user",
          password:  "sendgrid-pass"
        }
      )
      Collavre::SesSettingsInterceptor.delivering_email(message)

      assert_equal "smtp.sendgrid.net", message.delivery_method.settings[:address]
      assert_equal "sendgrid-user",     message.delivery_method.settings[:user_name]
      assert_equal "sendgrid-pass",     message.delivery_method.settings[:password]
    end

    test "does not clear credentials on non-SES SMTP provider when no SES pair" do
      # Host using a non-SES provider with no SES configured — earlier code
      # would have deleted :user_name/:password (the P1 Codex caught).
      message = build_smtp_message(
        settings: {
          address:   "smtp.mailgun.org",
          port:      587,
          user_name: "mg-user",
          password:  "mg-pass"
        }
      )
      Collavre::SesSettingsInterceptor.delivering_email(message)

      assert_equal "smtp.mailgun.org", message.delivery_method.settings[:address]
      assert_equal "mg-user",          message.delivery_method.settings[:user_name]
      assert_equal "mg-pass",          message.delivery_method.settings[:password]
    end

    test "skips non-SMTP delivery methods" do
      message = ::Mail.new
      message.delivery_method :test
      assert_nothing_raised do
        Collavre::SesSettingsInterceptor.delivering_email(message)
      end
    end

    private

    # Mirrors production.rb's boot scaffold: when SES region is resolvable
    # the scaffold writes an `email-smtp.<region>.amazonaws.com` address,
    # which is the signal `SesSettingsInterceptor#ses_target?` uses to
    # decide it should inject. Tests that want the interceptor to fire
    # therefore start from an SES-shaped placeholder address; tests that
    # want it to pass through override with a non-SES address.
    def build_smtp_message(settings:)
      defaults = { address: "email-smtp.placeholder.amazonaws.com" }
      message = ::Mail.new
      message.delivery_method :smtp, defaults.merge(settings)
      message
    end
  end
end
