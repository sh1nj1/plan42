class CreativeShare < ApplicationRecord
  belongs_to :creative
  belongs_to :user

  enum :permission, {
    read: 0,
    read_tree: 1,
    write: 2,
    write_tree: 3
  }

  validates :creative_id, presence: true
  validates :user_id, presence: true
  validates :permission, presence: true
  validates :user_id, uniqueness: { scope: :creative_id }

  after_create :create_linked_creative, unless: :linked_creative_exists?

  private

  def create_linked_creative
    Creative.create!(
      origin_id: creative.id,
      user_id: user.id,
      parent_id: creative.parent_id,
      description: creative.description,
      progress: creative.progress
    )
  end

  def linked_creative_exists?
    Creative.exists?(origin_id: creative.id, user_id: user.id)
  end
end
