class CreativeExpandedState < ApplicationRecord
  belongs_to :creative, optional: true
  belongs_to :user

  validates :expanded_status, presence: true
  validates :creative_id, uniqueness: { scope: :user_id }, allow_nil: true
end
