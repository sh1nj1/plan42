class User < ApplicationRecord
  DEFAULT_DISPLAY_LEVEL = 6

  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :creatives
  has_many :labels, foreign_key: :owner_id

  has_one_attached :avatar

  attribute :display_level, :integer, default: DEFAULT_DISPLAY_LEVEL
  attribute :completion_mark, :string, default: ""

  normalizes :email, with: ->(e) { e.strip.downcase }

  validates :email, presence: true, uniqueness: true,
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :display_level, numericality: { only_integer: true, greater_than: 0 }

  generates_token_for :email_verification, expires_in: 1.day do
    email
  end

  def email_verified?
    email_verified_at.present?
  end
end
