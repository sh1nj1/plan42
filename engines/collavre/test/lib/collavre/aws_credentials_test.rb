# frozen_string_literal: true

require "test_helper"

module Collavre
  # `AwsCredentials` returns source-coherent pairs (both DB, both ENV, or both
  # Rails credentials). The half-configured DB case must fall through to a
  # coherent ENV/credentials pair — never combine a DB half with an ENV half.
  class AwsCredentialsTest < ActiveSupport::TestCase
    setup do
      Collavre::IntegrationSetting.delete_all
      %w[
        AWS_S3_ACCESS_KEY_ID AWS_S3_SECRET_ACCESS_KEY
        AWS_SES_SMTP_USERNAME AWS_SES_SMTP_PASSWORD
      ].each { |k| ENV.delete(k) }
      Rails.cache.clear
    end

    teardown do
      %w[
        AWS_S3_ACCESS_KEY_ID AWS_S3_SECRET_ACCESS_KEY
        AWS_SES_SMTP_USERNAME AWS_SES_SMTP_PASSWORD
      ].each { |k| ENV.delete(k) }
      Rails.cache.clear
    end

    test "s3 returns DB pair when both halves are set" do
      Collavre::IntegrationSetting.create!(key: "aws_s3_access_key_id", value: "DB-KEY", category: "aws_s3")
      Collavre::IntegrationSetting.create!(key: "aws_s3_secret_access_key", value: "DB-SECRET", category: "aws_s3")

      assert_equal({ access_key_id: "DB-KEY", secret_access_key: "DB-SECRET" }, Collavre::AwsCredentials.s3)
    end

    test "s3 falls through to ENV when only one DB half is set" do
      ENV["AWS_S3_ACCESS_KEY_ID"] = "ENV-KEY"
      ENV["AWS_S3_SECRET_ACCESS_KEY"] = "ENV-SECRET"
      Collavre::IntegrationSetting.create!(key: "aws_s3_access_key_id", value: "DB-KEY", category: "aws_s3")

      assert_equal({ access_key_id: "ENV-KEY", secret_access_key: "ENV-SECRET" }, Collavre::AwsCredentials.s3)
    end

    test "s3 returns empty hash when no coherent pair exists" do
      ENV["AWS_S3_ACCESS_KEY_ID"] = "ENV-KEY"
      assert_equal({}, Collavre::AwsCredentials.s3)
    end

    test "ses_smtp returns DB pair when both halves are set" do
      Collavre::IntegrationSetting.create!(key: "aws_ses_smtp_username", value: "db-u", category: "aws_ses")
      Collavre::IntegrationSetting.create!(key: "aws_ses_smtp_password", value: "db-p", category: "aws_ses")

      assert_equal({ user_name: "db-u", password: "db-p" }, Collavre::AwsCredentials.ses_smtp)
    end

    test "ses_smtp falls through to ENV when only one DB half is set" do
      ENV["AWS_SES_SMTP_USERNAME"] = "env-u"
      ENV["AWS_SES_SMTP_PASSWORD"] = "env-p"
      Collavre::IntegrationSetting.create!(key: "aws_ses_smtp_username", value: "db-u", category: "aws_ses")

      assert_equal({ user_name: "env-u", password: "env-p" }, Collavre::AwsCredentials.ses_smtp)
    end

    test "returns empty hash for partial ENV (no full source available)" do
      ENV["AWS_SES_SMTP_USERNAME"] = "env-u"
      assert_equal({}, Collavre::AwsCredentials.ses_smtp)
    end

    test "falls through to ENV when DB decrypt raises at boot (encryption not configured)" do
      # Simulates the boot window where `:load_environment_config` runs before
      # the host app's encryption initializer wires up keys: reading the
      # encrypted `value` column raises an encryption error. AwsCredentials
      # must treat that as "DB unavailable" so the ENV pair still wins.
      ENV["AWS_S3_ACCESS_KEY_ID"] = "ENV-KEY"
      ENV["AWS_S3_SECRET_ACCESS_KEY"] = "ENV-SECRET"
      Collavre::IntegrationSetting.stub(:find_by, ->(*_) { raise ActiveRecord::Encryption::Errors::Configuration, "no key" }) do
        assert_equal({ access_key_id: "ENV-KEY", secret_access_key: "ENV-SECRET" }, Collavre::AwsCredentials.s3)
      end
    end
  end
end
