class Tag < ApplicationRecord
  belongs_to :label
  validates :creative_id, presence: true
  # value 컬럼이 추가되었습니다.
end
