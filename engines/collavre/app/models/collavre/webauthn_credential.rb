module Collavre
  class WebauthnCredential < ApplicationRecord
    self.table_name = "webauthn_credentials"

    belongs_to :user, class_name: "Collavre::User"

    validates :webauthn_id, presence: true, uniqueness: true
    validates :public_key, presence: true
    validates :sign_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  end
end
