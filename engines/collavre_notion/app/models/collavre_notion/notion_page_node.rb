module CollavreNotion
  class NotionPageNode < ApplicationRecord
    self.table_name = "notion_page_nodes"

    belongs_to :notion_page_link, class_name: "CollavreNotion::NotionPageLink"
    validates :creative_id, :page_id, :parent_page_id, presence: true
    validates :creative_id, uniqueness: { scope: :notion_page_link_id }
  end
end
