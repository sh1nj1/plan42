class Plan < ApplicationRecord
  validates :target_date, presence: true
end
