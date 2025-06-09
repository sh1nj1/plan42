require "ostruct"
class Creative < ApplicationRecord
  include Notifications

  has_many :subscribers, dependent: :destroy
  has_rich_text :description
  has_many :comments, dependent: :destroy

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
    origin_id.nil? ? super : origin.children_with_permission(Current.user, :read)
  end

  def owning_parent
    if parent.present?
      Creative.find_by(origin_id: parent.id, user: Current.user) || parent
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

  private

  def has_permission_impl(user, required_permission = :read)
    return true if self.user_id == user.id
    share = CreativeShare.find_by(user: user, creative: self)
    return false unless share
    CreativeShare.permissions[share.permission] >= CreativeShare.permissions[required_permission.to_s]
  end
end
