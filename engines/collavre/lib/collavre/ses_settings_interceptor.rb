# frozen_string_literal: true

module Collavre
  # ActionMailer interceptor that injects AWS SES SMTP settings (address,
  # user_name, password) into each outgoing message at send time, sourced
  # from `IntegrationSettings` (DB > ENV) with a Rails credentials fallback.
  #
  # Registered via `Collavre::Engine` so admins can rotate SES credentials
  # through `/admin/integrations` without redeploying. Only acts on SMTP
  # delivery — other delivery methods (`:test`, `:letter_opener`, etc.) pass
  # through untouched.
  class SesSettingsInterceptor
    class << self
      def delivering_email(message)
        return unless message.delivery_method.is_a?(::Mail::SMTP)

        region = resolve_region
        creds  = Collavre::AwsCredentials.ses_smtp

        settings = message.delivery_method.settings
        settings[:address] = "email-smtp.#{region}.amazonaws.com" if region.present?
        # `AwsCredentials.ses_smtp` returns only source-coherent pairs (both DB,
        # both ENV, or both credentials). When admins save just one half via
        # /admin/integrations while the other still lives in ENV, the helper
        # drops the partial DB write and falls through to a coherent ENV/cred
        # pair, avoiding mismatched (db-user, env-pass) injections that would
        # break every SMTP delivery.
        if creds[:user_name].present? && creds[:password].present?
          settings[:user_name] = creds[:user_name]
          settings[:password]  = creds[:password]
        end
      end

      private

      def resolve_region
        value = Collavre::IntegrationSettings.fetch(:aws_region, default: ENV["AWS_REGION"])
        value.presence || Rails.application.credentials.dig(:aws, :region)
      end
    end
  end
end
