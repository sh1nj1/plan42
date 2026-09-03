module Collavre
  class Topic < ApplicationRecord
    self.table_name = "topics"

    belongs_to :creative, class_name: "Collavre::Creative"
    belongs_to :user, class_name: Collavre.configuration.user_class_name
    belongs_to :source_topic, class_name: "Collavre::Topic", optional: true
    belongs_to :primary_agent, class_name: Collavre.configuration.user_class_name, optional: true

    has_many :comments, class_name: "Collavre::Comment", dependent: :destroy
    has_many :channels, class_name: "Collavre::Channel", dependent: :destroy
    # Compress/merge snapshots capture a topic's comments as a restore point. The
    # comment_snapshots -> topics FK has no DB-level ON DELETE, so without this the
    # row blocks topic deletion (ActiveRecord::InvalidForeignKey -> 500). Once the
    # topic is gone the snapshot can no longer be restored into it, so :destroy.
    has_many :comment_snapshots, class_name: "Collavre::CommentSnapshot", dependent: :destroy
    has_many :branches, class_name: "Collavre::Topic", foreign_key: :source_topic_id, dependent: :nullify
    has_many :user_creative_preferences_as_last_topic, class_name: "Collavre::UserCreativePreference",
             foreign_key: :last_topic_id, dependent: :nullify, inverse_of: :last_topic

    # The dependent nullify below clears a user's selected topic without going
    # through the preference controller. Advance the ordering token first so a
    # client can distinguish that deletion from an older empty preference.
    before_destroy :advance_last_topic_preference_revisions, prepend: true

    # --- Archive scopes ---
    scope :active, -> { where(archived_at: nil) }
    scope :archived, -> { where.not(archived_at: nil) }

    validates :name, presence: true, uniqueness: { scope: :creative_id }

    before_create :set_default_position
    after_create :keep_history_topic_last

    default_scope { order(:position) }

    # Sets or replaces the primary agent for this topic
    def set_primary_agent!(agent)
      update!(primary_agent: agent)
    end

    # A primary agent is an exclusive assignment: Matcher#match_by_primary_agent
    # routes ambient events to it alone and returns [] — silence, not a fallback
    # — when it cannot respond. Routing also requires :feedback on the creative,
    # so pinning an agent that lacks it would disable the topic outright: the
    # pinned agent is not permitted to answer, and every other agent is excluded
    # by the assignment. User.mentionable_for and the agent palette both surface
    # searchable agents regardless of creative access, so this is reachable from
    # plain drag-and-drop or `/topic "name" @agent:`, not just a crafted request.
    #
    # This deliberately mirrors BOTH predicates Matcher applies before it will
    # route to a primary agent — #has_creative_permission? and
    # #eligible_in_inbox? — so "assignable" and "can respond" cannot drift
    # apart. Checking only the permission is not enough: registration grants a
    # Claude Channel agent inbox-wide :feedback, so it passes that check on
    # every inbox topic while Matcher confines it to its own session topic.
    # Pinning one on an ordinary inbox topic would therefore silence the topic
    # for everyone, and it is reachable by plain drag-and-drop (the agent is
    # created_by the user, so the palette lists it) or by `/topic "Main" @agent:`
    # (the inbox share puts it in User.mentionable_for regardless of searchable).
    #
    # Returns nil when assignable, otherwise a symbol naming the reason, so
    # callers can render a message that says which rule was hit.
    #
    # Deliberately NOT enforced inside #set_primary_agent!: SessionProvisioner
    # and Api::V1::AgentsController#register write the pin as session identity
    # before the inbox share exists, and must not be gated on it.
    def self.primary_agent_rejection(creative, agent, topic: nil)
      return :not_an_agent unless agent&.ai_user?
      return :no_creative_access unless creative&.has_permission?(agent, :feedback)

      # Mirror Matcher#eligible_in_inbox?
      return nil unless creative.inbox?
      return nil unless agent.claude_channel_agent?
      return nil if topic&.session_id.present? && topic.primary_agent_id == agent.id

      :session_agent_outside_session_topic
    end

    def self.primary_agent_assignable?(creative, agent, topic: nil)
      primary_agent_rejection(creative, agent, topic: topic).nil?
    end

    def archived?
      archived_at.present?
    end

    def archive!
      update!(archived_at: Time.current)
    end

    def unarchive!
      update!(archived_at: nil)
    end

    private

    def advance_last_topic_preference_revisions
      user_creative_preferences_as_last_topic.update_all("last_topic_revision = last_topic_revision + 1")
    end

    def set_default_position
      return if position_changed? && position != 0

      self.position = (Topic.unscoped.where(creative_id: creative_id).maximum(:position) || -1) + 1
    end

    def keep_history_topic_last
      return if name == Creative::HISTORY_TOPIC_NAME

      history = Topic.unscoped.find_by(creative_id: creative_id, name: Creative::HISTORY_TOPIC_NAME)
      history&.update_column(:position, position + 1) if history&.position.to_i <= position
    end
  end
end
