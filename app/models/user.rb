class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :creatives
  has_many :labels, foreign_key: :owner_id

  normalizes :email, with: ->(e) { e.strip.downcase }

  validates :theme, inclusion: { in: %w[light dark] }
end
