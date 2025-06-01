class Label < ApplicationRecord
  has_many :tags, dependent: :destroy
  # STI: Plan, Variation 등 서브클래스에서 type 컬럼 사용
  # name, value, target_date 등 속성 포함
end
