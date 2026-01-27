module Collavre
  class Email < ApplicationRecord
    self.table_name = "emails"

    belongs_to :user, class_name: Collavre.configuration.user_class_name, optional: true

    enum :event, {
      invitation: "invitation",
      inbox_summary: "inbox_summary"
    }

    validates :email, :subject, :event, presence: true
  end
end
