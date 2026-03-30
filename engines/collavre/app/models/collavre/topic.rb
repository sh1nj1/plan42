module Collavre
  class Topic < ApplicationRecord
    self.table_name = "topics"

    belongs_to :creative, class_name: "Collavre::Creative"
    belongs_to :user, class_name: Collavre.configuration.user_class_name
    belongs_to :source_topic, class_name: "Collavre::Topic", optional: true
    belongs_to :primary_agent, class_name: Collavre.configuration.user_class_name, optional: true

    has_many :comments, class_name: "Collavre::Comment", dependent: :destroy
    has_many :channels, class_name: "Collavre::Channel", dependent: :destroy
    has_many :branches, class_name: "Collavre::Topic", foreign_key: :source_topic_id, dependent: :nullify
    has_many :user_creative_preferences_as_last_topic, class_name: "Collavre::UserCreativePreference",
             foreign_key: :last_topic_id, dependent: :nullify, inverse_of: :last_topic

    # --- Archive scopes ---
    scope :active, -> { where(archived_at: nil) }
    scope :archived, -> { where.not(archived_at: nil) }

    validates :name, presence: true, uniqueness: { scope: :creative_id }

    before_create :set_default_position

    default_scope { order(:position) }

    # Sets or replaces the primary agent for this topic
    def set_primary_agent!(agent)
      update!(primary_agent: agent)
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

    def set_default_position
      return if position_changed? && position != 0

      self.position = (Topic.unscoped.where(creative_id: creative_id).maximum(:position) || -1) + 1
    end
  end
end
