module Collavre
  class Invitation < ApplicationRecord
    self.table_name = "invitations"

    belongs_to :inviter, class_name: Collavre.configuration.user_class_name
    belongs_to :creative, class_name: "Collavre::Creative"

    enum :permission, CreativeShare.permissions

    generates_token_for :invite, expires_in: 15.days

    validates :expires_at, presence: true

    before_validation :set_default_expires_at, on: :create

    private

    def set_default_expires_at
      self.expires_at ||= 15.days.from_now
    end
  end
end
