class Comment < ApplicationRecord
  belongs_to :creative
  belongs_to :user, optional: true

  validates :content, presence: true
end
