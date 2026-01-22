module Collavre
  class Contact < ApplicationRecord
    self.table_name = "contacts"

    belongs_to :user, class_name: Collavre.configuration.user_class_name
    belongs_to :contact_user, class_name: Collavre.configuration.user_class_name

    validates :user_id, uniqueness: { scope: :contact_user_id }
    validate :cannot_add_self

    def self.ensure(user:, contact_user:)
      return if user.nil? || contact_user.nil? || user == contact_user

      find_or_create_by!(user: user, contact_user: contact_user)
    end

    private

    def cannot_add_self
      errors.add(:contact_user, :invalid) if user_id.present? && contact_user_id.present? && user_id == contact_user_id
    end
  end
end
