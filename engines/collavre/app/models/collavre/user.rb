module Collavre
  class User < ApplicationRecord
    self.table_name = "users"

    has_many :user_themes, class_name: "Collavre::UserTheme", dependent: :destroy
    DEFAULT_DISPLAY_LEVEL = 6

    has_secure_password
    has_many :sessions, class_name: "Collavre::Session", dependent: :destroy
    has_many :oauth_applications, class_name: "Doorkeeper::Application", as: :owner, dependent: :destroy
    has_many :access_grants, class_name: "Doorkeeper::AccessGrant", foreign_key: :resource_owner_id, dependent: :delete_all
    has_many :access_tokens, class_name: "Doorkeeper::AccessToken", foreign_key: :resource_owner_id, dependent: :delete_all
    has_many :webauthn_credentials, class_name: "Collavre::WebauthnCredential", dependent: :destroy
    has_many :devices, class_name: "Collavre::Device", dependent: :destroy
    has_many :emails, class_name: "Collavre::Email", dependent: :destroy
    has_many :contacts, class_name: "Collavre::Contact", dependent: :destroy
    has_many :contact_users, through: :contacts
    has_many :contact_memberships, class_name: "Collavre::Contact", foreign_key: :contact_user_id, dependent: :destroy, inverse_of: :contact_user
    has_one :github_account, class_name: "Collavre::GithubAccount", dependent: :destroy
    has_one :notion_account, class_name: "Collavre::NotionAccount", dependent: :destroy
    has_many :tasks, class_name: "Collavre::Task", foreign_key: :agent_id, dependent: :destroy

    # Associations that reference creatives - must be destroyed BEFORE creatives
    has_many :topics, class_name: "Collavre::Topic", dependent: :destroy
    has_many :calendar_events, class_name: "Collavre::CalendarEvent", dependent: :destroy
    has_many :comment_read_pointers, class_name: "Collavre::CommentReadPointer", dependent: :destroy
    has_many :creative_expanded_states, class_name: "Collavre::CreativeExpandedState", dependent: :destroy
    has_many :creative_shares, class_name: "Collavre::CreativeShare", dependent: :destroy
    has_many :creative_shares_caches, class_name: "Collavre::CreativeSharesCache", dependent: :delete_all
    has_many :shared_creative_shares, class_name: "Collavre::CreativeShare", foreign_key: :shared_by_id,
                                      dependent: :nullify, inverse_of: :shared_by
    has_many :inbox_items, class_name: "Collavre::InboxItem", foreign_key: :owner_id, dependent: :destroy, inverse_of: :owner
    has_many :invitations, class_name: "Collavre::Invitation", foreign_key: :inviter_id, dependent: :destroy, inverse_of: :inviter
    has_many :activity_logs, class_name: "Collavre::ActivityLog", dependent: :destroy
    has_many :labels, class_name: "Collavre::Label", foreign_key: :owner_id, dependent: :destroy
    has_many :comments, class_name: "Collavre::Comment", dependent: :destroy
    has_many :action_executed_comments, class_name: "Collavre::Comment", foreign_key: :action_executed_by_id,
                                        dependent: :nullify, inverse_of: :action_executed_by
    has_many :approved_comments, class_name: "Collavre::Comment", foreign_key: :approver_id,
                                 dependent: :nullify, inverse_of: :approver
    has_many :comment_reactions, class_name: "Collavre::CommentReaction", dependent: :destroy

    # Creatives must be destroyed AFTER all associations that reference them
    has_many :creatives, class_name: "Collavre::Creative", dependent: :destroy

    belongs_to :creator, class_name: "Collavre::User", foreign_key: "created_by_id", optional: true
    has_many :created_ai_users, class_name: "Collavre::User", foreign_key: "created_by_id", dependent: :destroy

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
    attribute :searchable, :boolean, default: false

    attribute :google_uid, :string
    attribute :google_access_token, :string
    attribute :google_refresh_token, :string
    attribute :google_token_expires_at, :datetime

    attribute :system_prompt, :string
    attribute :llm_vendor, :string
    attribute :llm_model, :string
    attribute :llm_api_key, :string
    attribute :tools, :json, default: -> { [] }

    encrypts :llm_api_key, deterministic: false
    encrypts :google_access_token, deterministic: false
    encrypts :google_refresh_token, deterministic: false

    SUPPORTED_LLM_MODELS = [
      "gemini-2.5-flash",
      "gemini-1.5-flash",
      "gemini-1.5-pro"
    ].freeze

    def ai_user?
      llm_vendor.present?
    end

    def self.mentionable_for(creative)
      scope = where(searchable: true)
      return scope unless creative

      origin = creative.effective_origin
      permitted_users = [ origin.user ].compact + origin.all_shared_users(:feedback).map(&:user)
      permitted_ids = permitted_users.compact.map(&:id)
      permitted_ids.any? ? scope.or(where(id: permitted_ids)) : scope
    end

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
    validate :theme_accessibility
    validate :password_meets_minimum_length
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

    # Account lockout methods
    def locked?
      locked_at.present? && locked_at > Collavre::SystemSetting.lockout_duration.ago
    end

    def lock_account!
      update_columns(locked_at: Time.current)
    end

    def unlock_account!
      update_columns(locked_at: nil, failed_login_attempts: 0)
    end

    def record_failed_login!
      new_count = (failed_login_attempts || 0) + 1
      if new_count >= Collavre::SystemSetting.max_login_attempts
        update_columns(failed_login_attempts: new_count, locked_at: Time.current)
      else
        update_column(:failed_login_attempts, new_count)
      end
    end

    def reset_failed_login_attempts!
      update_column(:failed_login_attempts, 0) if failed_login_attempts.to_i > 0
    end

    def remaining_lockout_time
      return 0 unless locked?
      ((locked_at + Collavre::SystemSetting.lockout_duration) - Time.current).to_i
    end

    def password_meets_minimum_length
      return if password.blank?

      min_length = Collavre::SystemSetting.password_min_length
      if password.length < min_length
        errors.add(:password, :too_short, count: min_length)
      end
    end

    def theme_accessibility
      return if theme.blank? || %w[light dark].include?(theme)

      unless user_themes.exists?(id: theme)
        errors.add(:theme, "is invalid")
      end
    end
  end
end
