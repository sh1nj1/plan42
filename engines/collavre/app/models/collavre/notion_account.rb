module Collavre
  class NotionAccount < ApplicationRecord
    self.table_name = "notion_accounts"

    belongs_to :user, class_name: Collavre.configuration.user_class_name
    has_many :notion_page_links, class_name: "Collavre::NotionPageLink", dependent: :destroy

    encrypts :token, deterministic: false

    validates :notion_uid, :token, presence: true
    validates :notion_uid, uniqueness: true

    def expired?
      token_expires_at.present? && token_expires_at < Time.current
    end
  end
end
