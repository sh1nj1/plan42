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

    unless const_defined?(:DEFAULT_GITHUB_GEMINI_PROMPT)
      DEFAULT_GITHUB_GEMINI_PROMPT = <<~PROMPT.freeze
        You are reviewing a GitHub pull request and mapping it to Creative tasks.
        Pull request title: \#{pr_title}
        Pull request body:
        \#{pr_body}

        Pull request commit messages:
        \#{commit_messages}

        Pull request diff:
        \#{diff}

        Creative tree structure. Each line represents a creative node with indentation indicating depth (4 spaces per level).
        Format: - {"id": <ID>, "progress": <0.0-1.0>, "desc": "<Description>"}
        \#{creative_tree}

        \#{language_instructions}

        When describing creatives, write from an end-user perspective similar to a user manual. Avoid unnecessary technical detail, and keep sentences concise.

        Return a JSON object with two keys:
        - "completed": array of objects representing tasks finished by this PR. Each object must include "creative_id" (from the IDs above). Use only creatives marked [LEAF] in the list above. Optionally include "progress" (0.0 to 1.0), "note", or "path" for context.
        - "additional": array of objects for new creatives that are not already represented in the tree above. Each object must include "parent_id" (from the IDs above) and "description" (the new creative text). Do not use this list for follow-up tasks on existing creatives—only describe brand new creatives. Optionally include "progress" (0.0 to 1.0), "note", or "path".

        Do not add tasks to "completed" if they already show 100% progress in the tree above unless this PR clearly made new changes that justify marking them complete.

        Use only IDs present in the tree. Respond with valid JSON only.
      PROMPT
    end

    include Linkable
    include Permissible
    include Describable

    has_many :comments, class_name: "Collavre::Comment", dependent: :destroy
    has_many :comment_read_pointers, class_name: "Collavre::CommentReadPointer", dependent: :delete_all

    has_closure_tree order: :sequence, name_column: :description, hierarchy_table_name: "creative_hierarchies"

    attr_accessor :filtered_progress

    belongs_to :user, class_name: Collavre.configuration.user_class_name, optional: true

    has_many :tags, class_name: "Collavre::Tag", dependent: :destroy
    has_many :creative_expanded_states, class_name: "Collavre::CreativeExpandedState", dependent: :delete_all
    has_many :invitations, class_name: "Collavre::Invitation", dependent: :delete_all
    # github_repository_links association added by CollavreGithub engine
    has_many :topics, class_name: "Collavre::Topic", dependent: :destroy
    has_many :mcp_tools, dependent: :destroy
    has_many :activity_logs, class_name: "Collavre::ActivityLog", dependent: :destroy
    has_many :calendar_events, class_name: "Collavre::CalendarEvent", dependent: :destroy
    has_many :labels, class_name: "Collavre::Label", dependent: :destroy

    validates :progress, numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0 }, unless: -> { origin_id.present? }

    validate :progress_cannot_change_if_has_origin, on: :update

    before_validation :assign_default_user, on: :create

    after_save :update_parent_progress
    after_destroy :update_parent_progress
    after_save :update_mcp_tools

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

    def github_gemini_prompt_template
      github_gemini_prompt.presence || DEFAULT_GITHUB_GEMINI_PROMPT
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
  end
end
