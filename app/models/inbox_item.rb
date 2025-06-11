class InboxItem < ApplicationRecord
  belongs_to :owner, class_name: "User"

  attribute :state, :string, default: "new"
  validates :state, inclusion: { in: %w[new read archived] }
  validates :message, presence: true

  scope :new_items, -> { where(state: "new") }
  scope :read_items, -> { where(state: "read") }
  scope :archived_items, -> { where(state: "archived") }
end

