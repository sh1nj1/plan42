class User < ApplicationRecord
  DEFAULT_DISPLAY_LEVEL = 6

  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :calendar_events, dependent: :destroy
  has_many :creatives, dependent: :destroy
  has_many :labels, foreign_key: :owner_id, dependent: :destroy
  has_many :devices, dependent: :destroy
  has_many :comment_read_pointers, dependent: :destroy
  has_many :creative_expanded_states, dependent: :destroy
  has_many :creative_shares, dependent: :destroy
  has_many :comments, dependent: :destroy
  has_many :emails, dependent: :destroy
  has_many :inbox_items, foreign_key: :owner_id, dependent: :destroy, inverse_of: :owner
  has_many :invitations, foreign_key: :inviter_id, dependent: :destroy, inverse_of: :inviter

  has_one_attached :avatar

  attribute :display_level, :integer, default: DEFAULT_DISPLAY_LEVEL
  attribute :completion_mark, :string, default: ""
  attribute :theme, :string
  attribute :calendar_id, :string
  attribute :name, :string
  attribute :notifications_enabled, :boolean
  attribute :timezone, :string
  attribute :locale, :string
  attribute :system_admin, :boolean, default: false

  attribute :google_uid, :string
  attribute :google_access_token, :string
  attribute :google_refresh_token, :string
  attribute :google_token_expires_at, :datetime

  normalizes :email, with: ->(e) { e.strip.downcase }
  normalizes :timezone, with: ->(tz) do
    tz = tz.to_s.strip
    next if tz.blank?
    ActiveSupport::TimeZone[tz]&.tzinfo&.identifier || tz
  end

  validates :email, presence: true, uniqueness: true,
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :name, presence: true
  validates :display_level, numericality: { only_integer: true, greater_than: 0 }
  validates :theme, inclusion: { in: [ "", "light", "dark" ] }, allow_nil: true
  validates :timezone,
            inclusion: { in: ActiveSupport::TimeZone.all.map { |z| z.tzinfo.identifier } },
            allow_nil: true

  generates_token_for :email_verification, expires_in: 1.day do
    email
  end

  def email_verified?
    email_verified_at.present?
  end

  def display_name
    name.presence || email
  end
end
