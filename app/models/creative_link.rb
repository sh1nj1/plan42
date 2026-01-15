class CreativeLink < ApplicationRecord
  belongs_to :parent, class_name: "Creative"
  belongs_to :origin, class_name: "Creative"
  belongs_to :created_by, class_name: "User"

  has_many :virtual_creative_hierarchies, dependent: :delete_all

  validates :parent_id, uniqueness: { scope: :origin_id, message: "already has a link to this origin" }
  validate :no_circular_reference
  validate :origin_not_descendant_of_parent

  after_create :build_virtual_hierarchy
  after_destroy :destroy_virtual_hierarchy

  private

  def no_circular_reference
    return unless origin_id && parent_id

    # Origin의 서브트리에 parent가 포함되어 있으면 순환 참조
    if CreativeHierarchy.exists?(ancestor_id: origin_id, descendant_id: parent_id)
      errors.add(:origin, "would create a circular reference")
    end
  end

  def origin_not_descendant_of_parent
    return unless origin_id && parent_id

    # Origin이 이미 parent의 자손이면 의미 없음
    if CreativeHierarchy.exists?(ancestor_id: parent_id, descendant_id: origin_id)
      errors.add(:origin, "is already a descendant of parent")
    end
  end

  def build_virtual_hierarchy
    Creatives::VirtualHierarchyBuilder.new(self).build
  end

  def destroy_virtual_hierarchy
    virtual_creative_hierarchies.delete_all
  end
end
