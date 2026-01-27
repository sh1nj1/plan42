module Collavre
  class NotionPageLink < ApplicationRecord
    self.table_name = "notion_page_links"

    belongs_to :creative, class_name: "Collavre::Creative"
    belongs_to :notion_account, class_name: "Collavre::NotionAccount"
    has_many :notion_block_links, class_name: "Collavre::NotionBlockLink", dependent: :destroy

    validates :page_id, :page_title, presence: true
    validates :page_id, uniqueness: true

    scope :recent, -> { order(last_synced_at: :desc) }
    scope :synced, -> { where.not(last_synced_at: nil) }

    def mark_synced!
      touch(:last_synced_at)
    end
  end
end
