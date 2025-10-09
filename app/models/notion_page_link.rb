class NotionPageLink < ApplicationRecord
  belongs_to :creative
  belongs_to :notion_account
  has_many :notion_block_links, dependent: :destroy

  validates :page_id, :page_title, presence: true
  validates :page_id, uniqueness: true

  scope :recent, -> { order(last_synced_at: :desc) }
  scope :synced, -> { where.not(last_synced_at: nil) }

  def mark_synced!
    touch(:last_synced_at)
  end
end
