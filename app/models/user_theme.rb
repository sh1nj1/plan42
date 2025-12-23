class UserTheme < ApplicationRecord
  belongs_to :user
  validates :name, presence: true
  validates :variables, presence: true
end
