class User < ApplicationRecord
  DEFAULT_DISPLAY_LEVEL = 6

  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :creatives
  has_many :labels, foreign_key: :owner_id

  has_one_attached :avatar

  attribute :display_level, :integer, default: DEFAULT_DISPLAY_LEVEL
  attribute :completion_mark, :string, default: ""
  attribute :theme, :string

  validates :google_uid, uniqueness: true, allow_nil: true

  normalizes :email, with: ->(e) { e.strip.downcase }

  validates :email, presence: true, uniqueness: true,
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :display_level, numericality: { only_integer: true, greater_than: 0 }
  validates :theme, inclusion: { in: [ "", "light", "dark" ] }, allow_nil: true

  generates_token_for :email_verification, expires_in: 1.day do
    email
  end

  def self.find_or_create_from_google(auth)
    find_or_initialize_by(google_uid: auth.uid).tap do |user|
      user.email = auth.info.email
      user.email_verified_at ||= Time.current
      user.password = SecureRandom.hex(16) if user.new_record?
      user.avatar_url = auth.info.image if auth.info.image.present?
      user.save!
    end
  end

  def email_verified?
    email_verified_at.present?
  end
end
