require "ostruct"
require "closure_tree"
class Creative < ApplicationRecord
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

  # has_rich_text :description
  has_many :comments, dependent: :destroy
  has_many :comment_read_pointers, dependent: :delete_all

  has_closure_tree order: :sequence, name_column: :description

  attr_accessor :filtered_progress

  # belongs_to :parent, class_name: "Creative", optional: true
  # has_many :children, -> { order(:sequence) }, class_name: "Creative", foreign_key: :parent_id, dependent: :destroy

  belongs_to :origin, class_name: "Creative", optional: true
  has_many :linked_creatives, class_name: "Creative", foreign_key: :origin_id, dependent: :delete_all
  belongs_to :user, optional: true

  has_many :creative_shares, dependent: :destroy
  has_many :tags, dependent: :destroy
  has_many :creative_expanded_states, dependent: :delete_all
  has_many :invitations, dependent: :delete_all
  has_many :github_repository_links, dependent: :destroy
  has_many :notion_page_links, dependent: :destroy
  has_many :notion_block_links, dependent: :destroy
  has_many :topics, dependent: :destroy
  has_many :mcp_tools, dependent: :destroy
  has_many :activity_logs, dependent: :destroy

  validates :progress, numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0 }, unless: -> { origin_id.present? }
  validates :description, presence: true, unless: -> { origin_id.present? }

  validate :progress_cannot_change_if_has_origin, on: :update
  validate :description_cannot_change_if_has_origin, on: :update
  validate :origin_cannot_be_self

  before_validation :assign_default_user, on: :create
  before_validation :redirect_parent_to_origin
  before_save :sanitize_description_html

  after_save :update_parent_progress
  after_save :clear_permission_cache_on_parent_change
  after_save :clear_permission_cache_on_user_change
  after_destroy :update_parent_progress
  after_destroy_commit :purge_description_attachments
  after_save :update_mcp_tools





  def has_permission?(user, required_permission = :read)
    Creatives::PermissionChecker.new(self, user).allowed?(required_permission)
  end

  # Returns only children for which the user has at least the given permission (default: :read)
  def children_with_permission(user = nil, min_permission = :read)
    user ||= Current.user
    effective_origin(Set.new).children.select do |child|
      child.has_permission?(user, min_permission)
    end
  end

  # Returns the effective attribute for linked creatives
  def effective_attribute(attr, visited_ids = Set.new)
    return self[attr] if origin_id.nil? || attr.to_s == "parent_id"
    return self[attr] if visited_ids.include?(id)

    visited_ids.add(id)
    origin.effective_attribute(attr, visited_ids)
  end

  def effective_origin(visited_ids = Set.new)
    return self if origin_id.nil?
    return self if visited_ids.include?(id)

    visited_ids.add(id)
    origin.effective_origin(visited_ids)
  end

  # Compatibility helper: ancestry gem exposes `subtree_ids`, while
  # closure_tree typically uses `self_and_descendants`.
  # Provide `subtree_ids` so call sites (e.g., controller search) work.
  def subtree_ids
    self_and_descendants.pluck(:id)
  end

  # Linked Creative의 description을 안전하게 반환
  # variation_id가 주어지면 해당 Variation의 Tag value를 반환, 없으면 기존 description 반환
  def effective_description(variation_id = nil, html = true)
    if variation_id.present?
      variation_tag = tags.find_by(label_id: variation_id)
      return variation_tag.value if variation_tag&.value.present?
    end
    if origin_id.nil?
      description_val = description
    else
      description_val = origin.description
    end
    if html
      description_val&.to_s || ""
    else
      # For plain text, we might need to strip tags if description is HTML
      # But the original code used rich_text_description&.body which returns ActionText::Content
      # which has to_s (HTML) and to_plain_text.
      # Since we now store raw HTML, we should strip tags for plain text.
      ActionController::Base.helpers.strip_tags(description_val&.to_s || "")
    end
  end

  def creative_snippet
    ActionController::Base.helpers.strip_tags(effective_origin.description || "").truncate(24, omission: "...")
  end

  def progress
    effective_attribute(:progress, Set.new)
  end

  def user
    target = effective_origin(Set.new)
    return super if target == self

    target.user
  end

  def children
    # better not override this method, use children_with_permission instead or linked_children
    super
  end

  def linked_children
    origin_id.nil? ? children : origin.children_with_permission(Current.user, :read)
  end

  def owning_parent
    if parent.present?
      Creative.find_by(origin_id: parent.id, user: Current.user) || parent
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

  def progress_for_tags(tag_ids, user = Current.user)
    progress_service.progress_for_tags(tag_ids, user)
  end

  # Calculate progress for the subtree ignoring permission checks.
  # `tagged_ids` should be a Set of creative IDs that are tagged with the plan.
  def progress_for_plan(tagged_ids)
    progress_service.progress_for_plan(tagged_ids)
  end

  # 공유 대상 사용자를 위해 Linked Creative를 생성합니다.
  # 이미 존재하거나 원본 작성자에게는 생성하지 않습니다.
  def create_linked_creative_for_user(user)
    original = effective_origin(Set.new)
    return if original.user_id == user.id
    ancestor_ids = original.ancestors.pluck(:id)
    has_ancestor_share = CreativeShare.where(creative_id: ancestor_ids, user_id: user.id)
                                      .where.not(permission: :no_access)
                                      .exists?
    has_owning_ancestors = Creative.where(id: ancestor_ids, user_id: user.id)
                                        .exists?
    return if has_ancestor_share or has_owning_ancestors
    Creative.find_or_create_by!(origin_id: original.id, user_id: user.id) do |c|
      c.parent_id = nil
    end
  end

  def update_parent_progress
    progress_service.update_parent_progress!

    if saved_change_to_parent_id?
      old_parent_id = saved_change_to_parent_id[0]
      if old_parent_id && (old_parent = Creative.find_by(id: old_parent_id))
        Creatives::ProgressService.new(old_parent).update_progress_from_children!
      end
    end
  end

  def all_shared_users(required_permission = :no_access)
    base_creative = effective_origin(Set.new)
    ancestor_ids = [ base_creative.id ] + base_creative.ancestors.pluck(:id)
    required_permission_level = CreativeShare.permissions.fetch(required_permission.to_s)

    shares = CreativeShare.where(creative_id: ancestor_ids).includes(:user)
    shares_for_user_hash = shares.group_by(&:user_id)

    shares_for_user_hash.filter_map do |_user_id, user_shares|
      closest_share = CreativeShare.closest_parent_share(ancestor_ids, user_shares)
      next unless closest_share

      closest_permission_level = CreativeShare.permissions.fetch(closest_share.permission.to_s)
      next if closest_permission_level < required_permission_level

      closest_share
    end
  end

  def github_gemini_prompt_template
    github_gemini_prompt.presence || DEFAULT_GITHUB_GEMINI_PROMPT
  end

  private

  def purge_description_attachments
    return if description.blank?

    signed_ids = extract_signed_ids_from_description
    return if signed_ids.empty?

    signed_ids.each do |signed_id|
      begin
        blob = ActiveStorage::Blob.find_signed(signed_id)
        next unless blob

        # Skip purging if another creative still references the blob
        next if Creative.where.not(id: id)
                        .where("description LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(signed_id)}%")
                        .exists?

        blob.purge
      rescue ActiveRecord::RecordNotFound, ActiveSupport::MessageVerifier::InvalidSignature
        Rails.logger.warn("Creative##{id}: could not find blob for signed_id=#{signed_id}")
      rescue => e
        Rails.logger.error("Creative##{id}: failed to purge blob #{signed_id}: #{e.message}")
      end
    end
  end

  def sanitize_description_html
    table_tags = %w[table thead tbody tfoot tr th td]
    table_attrs = %w[colspan rowspan]
    self.description = ActionController::Base.helpers.sanitize(
      description,
      tags: Rails::HTML5::SafeListSanitizer.allowed_tags.to_a + table_tags,
      attributes: Rails::HTML5::SafeListSanitizer.allowed_attributes.to_a + table_attrs + %w[data-lexical]
    )
  end

  def extract_signed_ids_from_description
    return [] if description.blank?

    html = description.to_s

    ids = html.scan(%r{/rails/active_storage/blobs/(?:redirect|proxy)/([^/?#]+)}).flatten
    ids += html.scan(%r{/rails/active_storage/blobs/([^/?#]+)}).flatten

    ids.uniq
  end

  def clear_permission_cache_on_parent_change
    return unless saved_change_to_parent_id?

    # Clear cache for this creative and all its descendants
    # Since parent change affects permission inheritance, we need to clear all cached permissions
    # Use effective_origin.id for each creative since that's what the cache key uses
    affected_creatives = self_and_descendants
    affected_creative_origin_ids = affected_creatives.map { |c| c.effective_origin.id }.uniq

    # Get all users who have shares in the old ancestor tree and new ancestor tree
    old_parent_id = parent_id_before_last_save
    new_parent_id = parent_id

    old_ancestor_ids = old_parent_id ? Creative.find(old_parent_id).self_and_ancestors.pluck(:id) : []
    new_ancestor_ids = new_parent_id ? Creative.find(new_parent_id).self_and_ancestors.pluck(:id) : []

    # Include the moved creative and its ancestors in the search
    all_relevant_creative_ids = (affected_creative_origin_ids + old_ancestor_ids + new_ancestor_ids).uniq

    # Find all users who have shares in any of these creatives
    share_user_ids = CreativeShare.where(creative_id: all_relevant_creative_ids).pluck(:user_id).compact

    # CRITICAL: Also include owners of affected subtree and ancestor trees
    # Owners get access via node.user_id == user&.id check, not via shares
    subtree_owner_ids = affected_creatives.pluck(:user_id).compact
    old_ancestor_owner_ids = old_ancestor_ids.any? ? Creative.where(id: old_ancestor_ids).pluck(:user_id).compact : []
    new_ancestor_owner_ids = new_ancestor_ids.any? ? Creative.where(id: new_ancestor_ids).pluck(:user_id).compact : []

    # Combine all affected user IDs
    affected_user_ids = (share_user_ids + subtree_owner_ids + old_ancestor_owner_ids + new_ancestor_owner_ids).uniq

    # Clear cache for affected creatives and users
    permission_levels = [ :read, :feedback, :write, :admin ]
    affected_user_ids.each do |user_id|
      affected_creative_origin_ids.each do |origin_id|
        permission_levels.each do |level|
          Rails.cache.delete("creative_permission:#{origin_id}:#{user_id}:#{level}")
        end
      end
    end
  end

  def clear_permission_cache_on_user_change
    return unless saved_change_to_user_id?

    # Clear cache for this creative and all its descendants
    # When ownership changes, permission logic changes for owners and all users
    # Use effective_origin.id for each creative since that's what the cache key uses
    affected_creatives = self_and_descendants
    affected_creative_origin_ids = affected_creatives.map { |c| c.effective_origin.id }.uniq

    # Get old and new owner IDs
    old_user_id, new_user_id = saved_change_to_user_id

    # Find all users who might have cached permissions for these creatives
    # We need to check both the old/new owners and users with shares
    affected_user_ids = Set.new
    affected_user_ids << old_user_id if old_user_id
    affected_user_ids << new_user_id if new_user_id

    # Also include users who have shares in this subtree or its ancestors
    # (their permissions might change due to ownership change)
    ancestor_ids = ancestors.pluck(:id)
    all_relevant_creative_ids = affected_creative_origin_ids + ancestor_ids
    share_user_ids = CreativeShare.where(creative_id: all_relevant_creative_ids).pluck(:user_id).compact
    affected_user_ids.merge(share_user_ids)

    # CRITICAL: Also include owners of affected subtree and ancestors
    # Owners get access via node.user_id == user&.id check, not via shares
    subtree_owner_ids = affected_creatives.pluck(:user_id).compact
    ancestor_owner_ids = ancestor_ids.any? ? Creative.where(id: ancestor_ids).pluck(:user_id).compact : []
    affected_user_ids.merge(subtree_owner_ids + ancestor_owner_ids)

    # Clear cache for all affected combinations
    permission_levels = [ :read, :feedback, :write, :admin ]
    affected_user_ids.each do |user_id|
      affected_creative_origin_ids.each do |origin_id|
        permission_levels.each do |level|
          Rails.cache.delete("creative_permission:#{origin_id}:#{user_id}:#{level}")
        end
      end
    end
  end

  def assign_default_user
    return if user.present?
    if parent_id.present? && parent
      self.user = parent.user
    else
      self.user = Current.user
    end
  end

  def progress_service
    @progress_service ||= Creatives::ProgressService.new(self)
  end

  def redirect_parent_to_origin
    if parent&.origin_id.present?
      self.parent = parent.origin
    end
  end

  def update_mcp_tools
    McpService.new.update_from_creative(self)
  end

  def progress_cannot_change_if_has_origin
    if origin_id.present? && will_save_change_to_progress?
      errors.add(:progress, "cannot be changed directly when linked to an origin")
    end
  end

  def description_cannot_change_if_has_origin
    if origin_id.present? && will_save_change_to_description?
      errors.add(:description, "cannot be changed directly when linked to an origin")
    end
  end

  def origin_cannot_be_self
    if origin_id.present? && origin_id == id
      errors.add(:origin_id, "cannot be the same as id")
    end
  end

  private

  def touch_subtree_on_move
    # When moving a tree, all descendants might have new effective permissions
    # so we must touch them to invalidate cache.
    # self is already touched by save.
    descendants.update_all(updated_at: Time.current)
  end
end
