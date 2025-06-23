class InboxItem < ApplicationRecord
  belongs_to :owner, class_name: "User"

  after_commit :broadcast_badge_update, on: %i[create update destroy] # adjust callbacks as needed

  attribute :state, :string, default: "new"
  validates :state, inclusion: { in: %w[new read archived] }
  validates :message, presence: true

  scope :new_items, -> { where(state: "new") }
  scope :read_items, -> { where(state: "read") }


  def read?
    state == "read"
  end

  private

  def broadcast_badge_update
    # Recompute the new count for this owner:
    new_count = InboxItem.where(owner: owner, state: "new").count

    # Use Turbo::StreamsChannel to broadcast replace to that user’s inbox stream:
    Turbo::StreamsChannel.broadcast_replace_to(
      [ "inbox", owner ],
      target: "inbox-badge",
      partial: "inbox/badge_component/count",
      locals: { count: new_count, badge_id: "inbox-badge" }
    )
  end
end
