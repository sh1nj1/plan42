# frozen_string_literal: true

module Collavre
  class ApiKey < ApplicationRecord
    self.table_name = "api_keys"

    TOKEN_PREFIX = "sk-collavre-"

    belongs_to :user, class_name: "Collavre::User"

    validates :name, presence: true
    validates :token_digest, presence: true, uniqueness: true
    validates :token_prefix, presence: true

    scope :active, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }

    def self.generate_token
      "#{TOKEN_PREFIX}#{SecureRandom.hex(24)}"
    end

    def self.create_with_token!(user:, name:, expires_at: nil)
      token = generate_token
      api_key = create!(
        user: user,
        name: name,
        token_digest: Digest::SHA256.hexdigest(token),
        token_prefix: token[0, 8],
        expires_at: expires_at
      )
      [ api_key, token ]
    end

    def self.find_by_token(token)
      return nil if token.blank?

      digest = Digest::SHA256.hexdigest(token)
      active.find_by(token_digest: digest)
    end

    def expired?
      expires_at.present? && expires_at < Time.current
    end

    def touch_last_used!
      update_column(:last_used_at, Time.current)
    end
  end
end
