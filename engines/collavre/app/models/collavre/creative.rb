require "ostruct"
require "closure_tree"

module Collavre
  class Creative < ApplicationRecord
    self.table_name = "creatives"

    # Use non-namespaced partial path for backward compatibility
    def to_partial_path
      "creatives/creative"
    end

    after_save :touch_subtree_on_move, if: :saved_change_to_parent_id?
    after_save :fire_drop_trigger_on_move, if: :saved_change_to_parent_id?
    after_create_commit :fire_drop_trigger_on_create, if: :parent_id?


    include Linkable
    include Permissible
    include Describable
    include RealtimeBroadcastable

    has_many :comments, class_name: "Collavre::Comment", dependent: :destroy
    has_many :comment_read_pointers, class_name: "Collavre::CommentReadPointer", dependent: :delete_all
    has_many :comment_snapshots, class_name: "Collavre::CommentSnapshot", dependent: :destroy

    has_closure_tree order: :sequence, name_column: :description, hierarchy_table_name: "creative_hierarchies"

    # --- Archive scopes ---
    scope :active, -> { where(archived_at: nil) }
    scope :archived, -> { where.not(archived_at: nil) }

    # --- Inbox ---
    scope :inboxes, -> { where("data->>'kind' = 'inbox'") }

    SYSTEM_TOPIC_NAME = "System"

    def inbox?
      data&.dig("kind") == "inbox"
    end

    # Find or create the "System" topic for this inbox creative.
    # Re-creates it if the user deletes it.
    def system_topic(fallback_user: user)
      topics.find_or_create_by!(name: SYSTEM_TOPIC_NAME) do |topic|
        topic.user = fallback_user
      end
    end

    # Find or create the inbox creative for a given user.
    # Places it as a root creative (no parent) owned by the user.
    def self.inbox_for(user)
      existing = where(user: user).inboxes.first
      return existing if existing

      create!(
        description: "📥 Inbox",
        data: { "kind" => "inbox" },
        user: user,
        progress: 0.0
      )
    end

    attr_accessor :filtered_progress

    belongs_to :user, class_name: Collavre.configuration.user_class_name, optional: true

    has_many :tags, class_name: "Collavre::Tag", dependent: :destroy
    has_many :user_creative_preferences, class_name: "Collavre::UserCreativePreference", dependent: :delete_all
    has_many :invitations, class_name: "Collavre::Invitation", dependent: :delete_all
    # github_repository_links association added by CollavreGithub engine
    has_many :topics, class_name: "Collavre::Topic", dependent: :destroy
    has_many :mcp_tools, dependent: :destroy
    has_many :activity_logs, class_name: "Collavre::ActivityLog", dependent: :destroy
    has_many :calendar_events, class_name: "Collavre::CalendarEvent", dependent: :destroy
    has_many :labels, class_name: "Collavre::Label", dependent: :destroy

    # Returns IDs of creatives that have at least one active share and are
    # accessible by the given user (owned or shared with/by them).
    # Includes linked creatives whose origin has shares.
    def self.shared_accessible_ids(user)
      own_ids = where(user_id: user.id).pluck(:id)
      shared_ids = CreativeShare
        .where.not(permission: :no_access)
        .where("user_id = :uid OR shared_by_id = :uid", uid: user.id)
        .pluck(:creative_id)

      accessible_ids = (own_ids | shared_ids).uniq

      # Direct shares on accessible creatives
      directly_shared = CreativeShare
        .where(creative_id: accessible_ids)
        .where.not(permission: :no_access)
        .pluck(:creative_id)

      # Linked creatives whose origin has shares
      origin_shared = where(id: accessible_ids)
        .where.not(origin_id: nil)
        .joins("INNER JOIN creative_shares ON creative_shares.creative_id = creatives.origin_id")
        .where.not(creative_shares: { permission: :no_access })
        .pluck(:id)

      (directly_shared | origin_shared).uniq
    end

    validates :progress, numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0 }, unless: -> { origin_id.present? }

    validate :progress_cannot_change_if_has_origin, on: :update

    before_validation :assign_default_user, on: :create

    after_save :update_parent_progress
    after_destroy :update_parent_progress
    after_save :update_mcp_tools

    # --- Drop Trigger ---
    def drop_trigger_enabled?
      data&.dig("trigger", "on_child_enter") == true
    end

    # --- Context IDs ---
    # Returns the directly-configured context creative IDs for this creative.
    def context_ids
      Array(data&.dig("context_ids"))
    end

    # Returns the effective context IDs: own + inherited from ancestors (deduplicated).
    def effective_context_ids(visited_ids = Set.new)
      return [] if visited_ids.include?(id)

      visited_ids.add(id)
      own = context_ids
      parent_ctx = parent&.effective_context_ids(visited_ids) || []
      (own + parent_ctx).uniq
    end

    # Returns context creatives (excludes self to avoid duplication).
    def context_creatives
      ids = effective_context_ids
      ids -= [ id ]
      Creative.where(id: ids)
    end

    # Compatibility helper: ancestry gem exposes `subtree_ids`, while
    # closure_tree typically uses `self_and_descendants`.
    def subtree_ids
      self_and_descendants.pluck(:id)
    end

    def children
      # better not override this method, use children_with_permission instead or linked_children
      super
    end

    def owning_parent
      if parent.present?
        Creative.find_by(origin_id: parent.id, user: Collavre.current_user) || parent
      end
    end

    def prompt_for(user)
      comments
        .where(private: true, user: user)
        .where("content LIKE ?", "> %")
        .order(created_at: :desc)
        .first
        &.content
        &.sub(/\A>\s*/i, "")
    end

    def progress_for_tags(tag_ids, user = Collavre.current_user)
      progress_service.progress_for_tags(tag_ids, user)
    end

    def progress_for_plan(tagged_ids)
      progress_service.progress_for_plan(tagged_ids)
    end

    def update_parent_progress
      progress_service.update_parent_progress!

      if saved_change_to_parent_id?
        old_parent_id = saved_change_to_parent_id[0]
        if old_parent_id && (old_parent = Creative.find_by(id: old_parent_id))
          Collavre::Creatives::ProgressService.new(old_parent).update_progress_from_children!
        end
      end
    end

    # --- Archive ---
    def archived?
      archived_at.present?
    end

    def archive!
      now = Time.current
      self.class.transaction do
        # Archive self and descendants
        self_and_descendants.where(archived_at: nil).update_all(archived_at: now)

        # If this is a linked creative, also archive the origin and its descendants
        origin = effective_origin(Set.new)
        if origin != self
          origin.self_and_descendants.where(archived_at: nil).update_all(archived_at: now)
          # Archive all other linked creatives of the origin
          origin.linked_creatives.where.not(id: id).find_each do |linked|
            linked.self_and_descendants.where(archived_at: nil).update_all(archived_at: now)
          end
        end

        # Also archive any linked creatives that point to this one
        linked_creatives.find_each do |linked|
          linked.self_and_descendants.where(archived_at: nil).update_all(archived_at: now)
        end

        reload
        parent&.reload
        Collavre::Creatives::ProgressService.new(parent).update_progress_from_children! if parent
      end
    end

    def unarchive!
      self.class.transaction do
        # Unarchive self and descendants
        self_and_descendants.where.not(archived_at: nil).update_all(archived_at: nil)

        # If this is a linked creative, also unarchive the origin and its descendants
        origin = effective_origin(Set.new)
        if origin != self
          origin.self_and_descendants.where.not(archived_at: nil).update_all(archived_at: nil)
          # Unarchive all other linked creatives of the origin
          origin.linked_creatives.where.not(id: id).find_each do |linked|
            linked.self_and_descendants.where.not(archived_at: nil).update_all(archived_at: nil)
          end
        end

        # Also unarchive any linked creatives that point to this one
        linked_creatives.find_each do |linked|
          linked.self_and_descendants.where.not(archived_at: nil).update_all(archived_at: nil)
        end

        reload
        parent&.reload
        Collavre::Creatives::ProgressService.new(parent).update_progress_from_children! if parent
      end
    end


    private

    def assign_default_user
      return if user.present?
      if parent_id.present? && parent
        self.user = parent.user
      else
        self.user = Collavre.current_user
      end
    end

    def progress_service
      @progress_service ||= Collavre::Creatives::ProgressService.new(self)
    end

    def update_mcp_tools
      McpService.new.update_from_creative(self)
    end

    def progress_cannot_change_if_has_origin
      if origin_id.present? && will_save_change_to_progress?
        errors.add(:progress, "cannot be changed directly when linked to an origin")
      end
    end

    def touch_subtree_on_move
      descendants.update_all(updated_at: Time.current)
    end

    def fire_drop_trigger_on_move
      # Skip on create — after_create_commit handles that case
      return if previously_new_record?

      new_parent_id = parent_id
      return unless new_parent_id

      new_parent = Creative.find_by(id: new_parent_id)
      return unless new_parent&.drop_trigger_enabled?

      DropTriggerJob.perform_later(new_parent.id, id)
    end

    def fire_drop_trigger_on_create
      return unless parent&.drop_trigger_enabled?

      DropTriggerJob.perform_later(parent_id, id)
    end
  end
end
