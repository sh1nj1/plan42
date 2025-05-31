class Variation < ApplicationRecord
  has_many :tags, as: :taggable
  # description 컬럼이 제거되었습니다.
end
