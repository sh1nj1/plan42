module Collavre
  class User < ApplicationRecord
    self.table_name = "users"

    include HasInboxCreative
    include HasProfileCreative

    has_many :user_themes, class_name: "Collavre::UserTheme", dependent: :destroy

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
    # github_account association is added dynamically by collavre_github engine
    has_many :tasks, class_name: "Collavre::Task", foreign_key: :agent_id, dependent: :destroy

    # Associations that reference creatives - must be destroyed BEFORE creatives
    has_many :topics, class_name: "Collavre::Topic", dependent: :destroy
    has_many :calendar_events, class_name: "Collavre::CalendarEvent", dependent: :destroy
    has_many :comment_read_pointers, class_name: "Collavre::CommentReadPointer", dependent: :destroy
    has_many :user_creative_preferences, class_name: "Collavre::UserCreativePreference", dependent: :destroy
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

    # Leaf-first destroy to avoid closure_tree find(parent_id) errors
    has_many :creatives, class_name: "Collavre::Creative", dependent: nil
    before_destroy :destroy_creatives_leaf_first

    # /compress and /merge summaries are durable recovery artifacts: they replace
    # the deleted original conversation and anchor the restore control (rendered
    # from the surviving result comment via CommentSnapshot). Detach them (nullify
    # author) BEFORE the comments dependent: :destroy cascade — prepend ensures we
    # run first — so deleting the authoring agent/user doesn't destroy the summary
    # and orphan the snapshot, which would erase the only path to restore the
    # compressed conversation.
    before_destroy :preserve_durable_summary_comments, prepend: true

    belongs_to :creator, class_name: "Collavre::User", foreign_key: "created_by_id", optional: true
    has_many :created_ai_users, class_name: "Collavre::User", foreign_key: "created_by_id", dependent: :destroy

    has_one_attached :avatar

    attribute :theme, :string
    attribute :calendar_id, :string
    attribute :name, :string
    attribute :notifications_enabled, :boolean
    attribute :timezone, :string
    attribute :locale, :string
    attribute :system_admin, :boolean, default: false
    attribute :searchable, :boolean, default: false

    # Typo correction (2D gating: typing-device AND input-location must both be on).
    attribute :typo_correction_enabled, :boolean, default: true
    attribute :typo_correction_threshold, :integer, default: 80
    attribute :typo_correction_on_soft_keyboard, :boolean, default: true
    attribute :typo_correction_on_voice, :boolean, default: true
    attribute :typo_correction_on_physical_keyboard, :boolean, default: false
    attribute :typo_correction_in_chat, :boolean, default: true
    attribute :typo_correction_in_editor, :boolean, default: false

    attribute :google_uid, :string
    attribute :google_access_token, :string
    attribute :google_refresh_token, :string
    attribute :google_token_expires_at, :datetime

    attribute :system_prompt, :string
    attribute :llm_vendor, :string
    attribute :llm_model, :string
    attribute :llm_api_key, :string
    attribute :gateway_url, :string
    attribute :tools, :json, default: -> { [] }
    attribute :agent_conf, :string

    # Default context settings for AI agents
    AGENT_CONF_DEFAULTS = {
      "context" => {
        "chat_history" => 50,
        "chat_history_size" => 100_000,
        "creative_children_level" => nil
      },
      "session" => { "enabled" => nil }
    }.freeze

    # Default creative children level when agent_conf doesn't specify one
    DEFAULT_CREATIVE_CHILDREN_LEVEL = 6

    # Returns parsed agent_conf merged with defaults
    def parsed_agent_conf
      defaults = AGENT_CONF_DEFAULTS.deep_dup
      return defaults if agent_conf.blank?

      user_conf = YAML.safe_load(agent_conf, permitted_classes: [ Symbol ]) || {}
      defaults.deep_merge(user_conf)
    rescue Psych::SyntaxError => e
      Rails.logger.warn("[User#parsed_agent_conf] Invalid YAML for user #{id}: #{e.message}")
      AGENT_CONF_DEFAULTS.deep_dup
    end

    # Convenience accessors for context settings
    def chat_history_limit
      parsed_agent_conf.dig("context", "chat_history") || 50
    end

    def chat_history_size_limit
      parsed_agent_conf.dig("context", "chat_history_size") || 100_000
    end

    # Returns the creative children depth level for AI context.
    # nil in agent_conf means use the default (6).
    # 0 = no children, 1 = direct children only, 2 = grandchildren, etc.
    def creative_children_level
      level = parsed_agent_conf.dig("context", "creative_children_level")
      level.nil? ? DEFAULT_CREATIVE_CHILDREN_LEVEL : level.to_i
    end

    # Whether this agent uses stateful sessions (incremental messaging).
    # nil in agent_conf = auto-detect via the AiClient adapter layer, which
    # vendor engines register into (core never string-matches a vendor name).
    def supports_session?
      explicit = parsed_agent_conf.dig("session", "enabled")
      return ActiveModel::Type::Boolean.new.cast(explicit) unless explicit.nil?
      return false if llm_vendor.blank?

      Collavre::AiClient.vendor_supports_session?(llm_vendor)
    end

    encrypts :llm_api_key, deterministic: false
    encrypts :google_access_token, deterministic: false
    encrypts :google_refresh_token, deterministic: false

    # Override encrypted attribute getters to handle decryption errors gracefully.
    # This prevents the entire request from failing when a token can't be decrypted
    # (e.g., if it was encrypted with a different key or is corrupted).
    %i[google_access_token google_refresh_token llm_api_key].each do |attr|
      define_method(attr) do
        super()
      rescue ActiveSupport::MessageEncryptor::InvalidMessage,
             ActiveRecord::Encryption::Errors::Decryption,
             OpenSSL::Cipher::CipherError => e
        Rails.logger.error("Failed to decrypt #{attr} for user #{id}: #{e.class}")
        nil
      end
    end

    TYPO_CORRECTION_DEVICES = %w[voice soft_keyboard physical_keyboard].freeze
    TYPO_CORRECTION_LOCATIONS = %w[chat editor].freeze

    # 2D gating: typo correction runs only when the master switch is on AND the
    # originating typing device AND the input location are both enabled. Unknown
    # device/location values are treated as disabled (fail closed).
    def typo_correction_active_for?(device:, location:)
      return false unless typo_correction_enabled

      device_on = case device.to_s
      when "voice" then typo_correction_on_voice
      when "soft_keyboard" then typo_correction_on_soft_keyboard
      when "physical_keyboard" then typo_correction_on_physical_keyboard
      else false
      end

      location_on = case location.to_s
      when "chat" then typo_correction_in_chat
      when "editor" then typo_correction_in_editor
      else false
      end

      device_on && location_on
    end

    # LLM_VENDOR_OPTIONS is resolved dynamically from the AiClient vendor-option
    # registry so core lists only its built-in providers while vendor engines
    # (e.g. OpenClaw) contribute their own. Resolved lazily via const_missing so
    # the value always reflects registrations made after this class first loads
    # (they run in a to_prepare hook), and existing views keep referring to the
    # constant unchanged.
    def self.const_missing(name)
      return Collavre::AiClient.vendor_options if name == :LLM_VENDOR_OPTIONS

      super
    end

    SUPPORTED_LLM_MODELS = [
      "gemini-3.1-flash-lite",
      "gemini-1.5-flash",
      "gemini-1.5-pro"
    ].freeze

    def ai_user?
      llm_vendor.present?
    end

    # Mirror the agent's system prompt into its profile creative as Markdown,
    # so the raw prompt lands losslessly in data["markdown_source"] — the
    # canonical home for the prompt. Writing the prompt straight into
    # `description` would run it through the HTML sanitizer (Describable), which
    # strips <thinking>/<tool_call> tags and entity-escapes < > &, corrupting
    # every prompt; the derived `description` is only a rendered display view.
    # The system_prompt column is legacy, pending removal.
    # No-op for humans and for prompt-less agents (profile keeps its name seed).
    def sync_profile_system_prompt!
      return unless ai_user?
      creative = profile_creative
      if system_prompt.present?
        return if creative.data&.dig("markdown_source") == system_prompt
        # Store the prompt verbatim: markdown_source is the canonical text sent
        # to the LLM, so an inline data-URI image must NOT be rewritten into a
        # blob path (which would mutate the prompt the agent receives).
        creative.skip_data_uri_rewrite = true
        creative.update!(content_type_input: "markdown", markdown_source: system_prompt)
      elsif creative.data&.dig("markdown_source").present?
        # The prompt was cleared. Demote out of markdown mode so the stale
        # markdown_source is dropped and render falls back to the (now-blank)
        # column — matching the pre-profile behavior where blanking the prompt
        # took effect immediately. Also reseed `description` back to the name
        # seed so the old rendered prompt doesn't stay visible/searchable on the
        # owned profile root. Without this, the old prompt stays authoritative.
        creative.update!(content_type_input: "html", description: name.to_s)
      end
    end

    # The effective system prompt for all read consumers. The canonical prompt
    # lives in the profile creative's data["markdown_source"]; the legacy
    # `system_prompt` column is the fallback for rows not yet backfilled. Every
    # prompt reader (orchestration matching, type classification, typo agent,
    # admin view) must route here so that editing the profile creative directly
    # takes effect everywhere, not just in AiAgentService.
    def effective_system_prompt
      profile_creative_if_present&.data&.dig("markdown_source").presence || system_prompt
    end

    def claude_channel_agent?
      llm_model == "claude-code"
    end

    scope :ai_agents, -> { where.not(llm_vendor: [ nil, "" ]) }

    def self.accessible_ai_agents_for(user)
      owned = ai_agents.where(created_by_id: user.id)
      searchable = ai_agents.where(searchable: true)
      owned.or(searchable).distinct.order(:name)
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
    validate :theme_accessibility
    validate :password_meets_minimum_length
    validates :timezone,
              inclusion: { in: ActiveSupport::TimeZone.all.map { |z| z.tzinfo.identifier } },
              allow_nil: true
    # Column is NOT NULL; clearing the profile field (or a crafted PATCH) casts to
    # nil and would raise a DB error on save. Validate so the form re-renders.
    validates :typo_correction_threshold,
              presence: true,
              numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }

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

    # Keep durable compress/merge summaries (snapshot result comments) alive when
    # their author is deleted: nullify authorship instead of cascading destroy.
    def preserve_durable_summary_comments
      Collavre::Comment
        .where(id: Collavre::CommentSnapshot.where(result_comment_id: comments.select(:id)).select(:result_comment_id))
        .update_all(user_id: nil)
    end

    # Destroy creatives deepest-first so closure_tree always finds its parent
    def destroy_creatives_leaf_first
      all_creatives = creatives.flat_map { |c| c.self_and_descendants.to_a }.uniq

      # Order by depth in memory. The subtree is contiguous within all_creatives
      # (every node between an owned root and its descendant is itself a
      # descendant), so following parent_id links yields the same leaf-first
      # ordering as self_and_ancestors.count without firing a COUNT query per
      # creative (the previous N+1).
      by_id = all_creatives.index_by(&:id)
      depth_of = lambda do |creative|
        depth = 0
        node = creative
        while node&.parent_id && (parent = by_id[node.parent_id])
          depth += 1
          node = parent
        end
        depth
      end

      all_creatives.sort_by { |c| -depth_of.call(c) }.each do |c|
        c.reload.destroy! if Creative.exists?(c.id)
      end
    end
  end
end
