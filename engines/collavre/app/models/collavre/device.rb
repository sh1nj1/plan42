module Collavre
  class Device < ApplicationRecord
    self.table_name = "devices"

    enum :device_type, { web: 0, pwa: 1, android: 2, ios: 3 }

    belongs_to :user, class_name: Collavre.configuration.user_class_name

    validates :client_id, presence: true, uniqueness: true
    validates :device_type, presence: true
    validates :fcm_token, presence: true, uniqueness: true
  end
end
