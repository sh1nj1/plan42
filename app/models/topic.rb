class Topic < ApplicationRecord
  belongs_to :creative
  belongs_to :user

  has_many :comments, dependent: :destroy

  validates :name, presence: true, uniqueness: { scope: :creative_id }
end
