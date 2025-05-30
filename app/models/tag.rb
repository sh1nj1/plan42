class Tag < ApplicationRecord
  belongs_to :taggable, polymorphic: true
  validates :creative_id, presence: true
end
