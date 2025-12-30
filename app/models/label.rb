class Label < ApplicationRecord
  has_many :tags, dependent: :destroy
  belongs_to :owner, class_name: "User", optional: true
  belongs_to :creative, optional: true
  # STI: Plan, Variation 등 서브클래스에서 type 컬럼 사용
  # name, value, target_date 등 속성 포함

  # Check if user has permission to read this label
  # If linked to a Creative, delegates to Creative's permission system
  # Otherwise falls back to owner-based or public (nil owner) visibility
  def readable_by?(user)
    return true if owner_id.present? && owner_id == user&.id

    if creative_id.present? && creative
      creative.has_permission?(user, :read)
    else
      owner_id.nil?
    end
  end
end
