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

        region   = resolve(:aws_region, %i[aws region])
        username = resolve(:aws_ses_smtp_username, %i[aws smtp_username])
        password = resolve(:aws_ses_smtp_password, %i[aws smtp_password])

        settings = message.delivery_method.settings
        settings[:address]   = "email-smtp.#{region}.amazonaws.com" if region.present?
        settings[:user_name] = username if username.present?
        settings[:password]  = password if password.present?
      end

      private

      def resolve(key, credentials_path)
        value = Collavre::IntegrationSettings.fetch(key)
        value.presence || Rails.application.credentials.dig(*credentials_path)
      end
    end
  end
end
