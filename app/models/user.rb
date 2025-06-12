class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :creatives
  has_many :labels, foreign_key: :owner_id

  normalizes :email, with: ->(e) { e.strip.downcase }

  validates :email, presence: true, uniqueness: true,
                    format: { with: URI::MailTo::EMAIL_REGEXP }

  generates_token_for :email_verification, expires_in: 1.day do
    email
  end

  def email_verified?
    email_verified_at.present?
  end
end
