# frozen_string_literal: true

module CollavreLinear
  class Account < ApplicationRecord
    self.table_name = "linear_accounts"

    belongs_to :user, class_name: "::User"

    encrypts :access_token, deterministic: false
    encrypts :refresh_token, deterministic: false

    validates :linear_uid, presence: true, uniqueness: true
    validates :access_token, presence: true

    def token_expired?
      token_expires_at.present? && token_expires_at < Time.current
    end

    def token_expiring_soon?(within: 5.minutes)
      token_expires_at.present? && token_expires_at < Time.current + within
    end
  end
end
