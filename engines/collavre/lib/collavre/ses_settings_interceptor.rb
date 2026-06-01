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
    SES_ADDRESS_PATTERN = /\Aemail-smtp\.[a-z0-9-]+\.amazonaws\.com\z/

    class << self
      def delivering_email(message)
        return unless message.delivery_method.is_a?(::Mail::SMTP)

        settings = message.delivery_method.settings
        # Scope to SES-bound messages only. The engine registers this
        # interceptor globally, so host apps using a non-SES SMTP provider
        # (SendGrid, Mailgun, custom relay) must pass through untouched —
        # otherwise we'd clobber their address/user_name/password.
        return unless ses_target?(settings)

        region = resolve_region
        creds  = Collavre::AwsCredentials.ses_smtp

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
        else
          # No coherent pair available (admin reset DB and no ENV/credentials
          # fallback). Clear stale settings so we don't keep using boot-time
          # or previously-injected credentials — these keys are registered
          # with requires_restart: false, so runtime reset must take effect.
          settings.delete(:user_name)
          settings.delete(:password)
        end
      end

      private

      # SES intent is signaled by the SMTP address: an SES endpoint (boot
      # scaffold or previous injection) — or the `Mail::SMTP` default
      # ("localhost") which means the host configured no real SMTP server.
      # An explicit non-SES address (smtp.sendgrid.net, etc.) means the host
      # chose a different provider — bail out so we don't clobber their
      # address or wipe their auth credentials.
      def ses_target?(settings)
        address = settings[:address].to_s
        return true if address.blank? || address == "localhost"

        address.match?(SES_ADDRESS_PATTERN)
      end

      def resolve_region
        value = Collavre::IntegrationSettings.fetch(:aws_region, default: ENV["AWS_REGION"])
        value.presence || Rails.application.credentials.dig(:aws, :region)
      end
    end
  end
end
