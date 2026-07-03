# frozen_string_literal: true

module CollavreLinear
  class Account < ApplicationRecord
    self.table_name = "linear_accounts"

    belongs_to :user, class_name: "::User"

    # account_id carries a RESTRICT foreign key, so a user delete (which cascades
    # here via has_one :linear_account, dependent: :destroy) would hit a FK
    # violation unless we tear the links down first. Cascades on to issue/comment
    # links via ProjectLink's own dependent chain.
    has_many :project_links, class_name: "CollavreLinear::ProjectLink", dependent: :destroy

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
