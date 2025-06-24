class Email < ApplicationRecord
  belongs_to :user, optional: true

  enum :event, {
    invitation: "invitation",
    inbox_summary: "inbox_summary"
  }

  validates :email, :subject, :event, presence: true
end
