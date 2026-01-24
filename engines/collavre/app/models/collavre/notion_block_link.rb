module Collavre
  class NotionBlockLink < ApplicationRecord
    self.table_name = "notion_block_links"

    belongs_to :notion_page_link, class_name: "Collavre::NotionPageLink"
    belongs_to :creative, class_name: "Collavre::Creative"

    validates :block_id, presence: true, uniqueness: { scope: :notion_page_link_id }
  end
end
