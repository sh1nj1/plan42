# frozen_string_literal: true

module Collavre
  # Returns source-coherent AWS credential pairs (S3 access key id + secret,
  # SES SMTP username + password). Both halves of a pair come from the same
  # source — DB > ENV > Rails credentials — so a partial admin save cannot
  # combine a DB-saved value with an ENV-only sibling and produce a
  # mismatched pair that breaks every upload or every SMTP delivery.
  #
  # Each entry is `[registry_key, label, env_var, credentials_path]`.
  # `credentials_path` may be nil when the pair has no Rails.credentials
  # fallback (S3 keys aren't carried in credentials by convention).
  module AwsCredentials
    module_function

    # @return [Hash{Symbol => String}] coherent S3 credential pair or `{}`
    def s3
      coherent_pair(
        [ :aws_s3_access_key_id,     :access_key_id,     "AWS_S3_ACCESS_KEY_ID",     nil ],
        [ :aws_s3_secret_access_key, :secret_access_key, "AWS_S3_SECRET_ACCESS_KEY", nil ]
      )
    end

    # @return [Hash{Symbol => String}] coherent SES SMTP credential pair or `{}`
    def ses_smtp
      coherent_pair(
        [ :aws_ses_smtp_username, :user_name, "AWS_SES_SMTP_USERNAME", %i[aws smtp_username] ],
        [ :aws_ses_smtp_password, :password,  "AWS_SES_SMTP_PASSWORD", %i[aws smtp_password] ]
      )
    end

    def coherent_pair(*entries)
      [ db_pair(entries), env_pair(entries), credentials_pair(entries) ]
        .find { |pair| pair.values.all?(&:present?) } || {}
    end

    def db_pair(entries)
      entries.to_h { |entry| [ entry[1], read_db(entry[0]) ] }
    end

    def env_pair(entries)
      entries.to_h { |entry| [ entry[1], ENV[entry[2]].presence ] }
    end

    def credentials_pair(entries)
      entries.to_h do |entry|
        path = entry[3]
        value = path ? Rails.application.credentials.dig(*path).presence : nil
        [ entry[1], value ]
      end
    end

    def read_db(key)
      return nil unless defined?(Collavre::IntegrationSetting)
      Collavre::IntegrationSetting.find_by(key: key.to_s)&.value.presence
    rescue ActiveRecord::StatementInvalid,
           ActiveRecord::NoDatabaseError,
           ActiveRecord::ConnectionNotEstablished,
           NameError
      nil
    rescue StandardError => e
      # Encryption may not be configured yet at boot-time (see
      # IntegrationSettings.fetch); treat as DB unavailable so callers fall
      # back to ENV/credentials instead of crashing app boot.
      raise unless defined?(ActiveRecord::Encryption::Errors::Base) &&
                   e.is_a?(ActiveRecord::Encryption::Errors::Base)
      nil
    end
  end
end
