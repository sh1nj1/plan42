class Tag < ApplicationRecord
  belongs_to :taggable, polymorphic: true
  validates :creative_id, presence: true
  # value 컬럼이 추가되었습니다.
end
