require "ostruct"
class Creative < ApplicationRecord
  include Notifications

  has_many :subscribers, dependent: :destroy
  has_rich_text :description
  has_many :comments, dependent: :destroy
  has_many :comment_read_pointers, dependent: :delete_all

  has_closure_tree order: :sequence, name_column: :description

  # belongs_to :parent, class_name: "Creative", optional: true
  # has_many :children, -> { order(:sequence) }, class_name: "Creative", foreign_key: :parent_id, dependent: :destroy

  belongs_to :origin, class_name: "Creative", optional: true
  has_many :linked_creatives, class_name: "Creative", foreign_key: :origin_id, dependent: :delete_all
  belongs_to :user, optional: true

  has_many :creative_shares, dependent: :destroy
  has_many :tags, dependent: :destroy

  validates :progress, numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0 }, unless: -> { origin_id.present? }
  validates :description, presence: true, unless: -> { origin_id.present? }

  before_validation :assign_default_user, on: :create

  after_save :update_parent_progress
  after_destroy :update_parent_progress

  def self.recalculate_all_progress!
    Creative.roots.find_each do |root|
      root.recalculate_subtree_progress!
    end
  end

  def recalculate_subtree_progress!
    if origin_id.nil?
      children.each(&:recalculate_subtree_progress!)
      if children.any?
        update(progress: children.average(:progress) || 0)
      end
    else
      origin.recalculate_subtree_progress!
    end
  end

  def has_permission?(user, required_permission = :read)
    origin_id.nil? ? has_permission_impl(user, required_permission) : origin.has_permission?(user, required_permission)
  end

  # Returns only children for which the user has at least the given permission (default: :read)
  def children_with_permission(user = nil, min_permission = :read)
    user ||= Current.user
    effective_origin.children.select do |child|
      child.has_permission?(user, min_permission)
    end
  end

  # Returns the effective attribute for linked creatives
  def effective_attribute(attr)
    return self[attr] if origin_id.nil? || attr.to_s == "parent_id"
    origin.send(attr)
  end

  def effective_origin
    return self if origin_id.nil?
    origin
  end

  # Linked Creative의 description을 안전하게 반환
  # variation_id가 주어지면 해당 Variation의 Tag value를 반환, 없으면 기존 description 반환
  def effective_description(variation_id = nil, html = true)
    if variation_id.present?
      variation_tag = tags.find_by(label_id: variation_id)
      return variation_tag.value if variation_tag&.value.present?
    end
    if origin_id.nil?
      description = rich_text_description&.body
    else
      description = origin.rich_text_description&.body
    end
    if html
      description&.to_s || ""
    else
      description
    end
  end

  def progress
    effective_attribute(:progress)
  end

  def user
    origin_id.nil? ? super : origin.user
  end

  def children
    # better not override this method, use children_with_permission instead or linked_children
    super
  end

  def linked_children
    origin_id.nil? ? super : origin.children_with_permission(Current.user, :read)
  end

  def owning_parent
    if parent.present?
      Creative.find_by(origin_id: parent.id, user: Current.user) || parent
    end
  end

  def progress_for_tags(tag_ids, user = Current.user)
    return progress if tag_ids.blank?

    tag_ids = Array(tag_ids).map(&:to_s)

    nodes = self_and_descendants.includes(:tags, :children)
    nodes_by_id = nodes.index_by(&:id)
    child_map = {}
    depth_map = {}

    stack = [ [ nodes_by_id[id], 0 ] ]
    until stack.empty?
      node, depth = stack.pop
      depth_map[node.id] = depth
      child_map[node.id] = node.children.to_a
      node.children.each { |child| stack.push([ child, depth + 1 ]) }
    end

    progress_map = {}
    depth_map.keys.sort_by { |nid| -depth_map[nid] }.each do |nid|
      node = nodes_by_id[nid]
      visible_children = child_map[nid].select { |child| child.has_permission?(user) }
      child_values = visible_children.map { |child| progress_map[child.id] }.compact

      progress_map[nid] = if child_values.any?
        child_values.sum.to_f / child_values.size
      else
        own_label_ids = node.tags.map { |t| t.label_id.to_s }
        if (own_label_ids & tag_ids).any?
          visible_children.any? ? 1.0 : node.progress
        else
          nil
        end
      end
    end

    progress_map[id]
  end

  # 공유 대상 사용자를 위해 Linked Creative를 생성합니다.
  # 이미 존재하거나 원본 작성자에게는 생성하지 않습니다.
  def create_linked_creative_for_user(user)
    original = effective_origin
    return if original.user_id == user.id
    Creative.find_or_create_by!(origin_id: original.id, user_id: user.id) do |c|
      c.parent_id = nil
    end
  end

  def update_parent_progress
    # 참조 하는 모든 Linked Creative 도 업데이트
    linked_creatives.update_all(progress: self[:progress])
    return unless parent
    parent.reload
    new_progress = parent.children.any? ? parent.children.map(&:progress).sum.to_f / parent.children.size : 0
    parent.update(progress: new_progress)
  end

  def all_shared_users(required_permission = :read)
    base_creative = effective_origin
    ancestor_ids = [ base_creative.id ] + base_creative.ancestors.pluck(:id)
    CreativeShare.where(creative_id: ancestor_ids)
                 .where("permission >= ?", CreativeShare.permissions[required_permission.to_s])
                 .includes(:user)
  end

  private

  def assign_default_user
    return if user.present?
    if parent_id.present? && parent
      self.user = parent.user
    else
      self.user = Current.user
    end
  end

  def has_permission_impl(user, required_permission = :read)
    return true if self.user_id == user&.id
    # self 및 ancestors 모두 검사
    cache = Current.respond_to?(:creative_share_cache) ? Current.creative_share_cache : nil
    ([ self ] + ancestors).each do |node|
      share = cache ? cache[node.id] : CreativeShare.find_by(user: user, creative: node)
      return true if share && CreativeShare.permissions[share.permission] >= CreativeShare.permissions[required_permission.to_s]
    end
    false
  end
end
