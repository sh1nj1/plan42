class Plan < ApplicationRecord
  has_many :tags, as: :taggable, dependent: :destroy
  validates :target_date, presence: true
end
