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
      Collavre::IntegrationSetting.create!(key: "aws_ses_smtp_username", value: "db-user", category: "aws")

      message = build_smtp_message(settings: { port: 587 })
      Collavre::SesSettingsInterceptor.delivering_email(message)

      assert_equal "db-user", message.delivery_method.settings[:user_name]
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

    test "skips non-SMTP delivery methods" do
      message = ::Mail.new
      message.delivery_method :test
      assert_nothing_raised do
        Collavre::SesSettingsInterceptor.delivering_email(message)
      end
    end

    private

    def build_smtp_message(settings:)
      message = ::Mail.new
      message.delivery_method :smtp, settings
      message
    end
  end
end
