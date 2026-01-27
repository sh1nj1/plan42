module Collavre
  class Tag < ApplicationRecord
    self.table_name = "tags"

    belongs_to :label, class_name: "Collavre::Label"

    validates :creative_id, presence: true
    # value 컬럼이 추가되었습니다.
  end
end
