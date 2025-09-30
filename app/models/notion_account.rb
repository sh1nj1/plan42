class NotionAccount < ApplicationRecord
  belongs_to :user
  has_many :notion_page_links, dependent: :destroy

  validates :notion_uid, :token, presence: true
  validates :notion_uid, uniqueness: true

  def expired?
    token_expires_at.present? && token_expires_at < Time.current
  end
end
