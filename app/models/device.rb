class Device < ApplicationRecord
  enum :device_type, { web: 0, pwa: 1, android: 2, ios: 3 }

  belongs_to :user

  validates :client_id, presence: true, uniqueness: true
  validates :device_type, presence: true
  validates :fcm_token, presence: true
end
