class NotionBlockLink < ApplicationRecord
  belongs_to :notion_page_link
  belongs_to :creative

  validates :block_id, presence: true
  validates :creative_id, uniqueness: { scope: :notion_page_link_id }
  validates :block_id, uniqueness: { scope: :notion_page_link_id }
end
