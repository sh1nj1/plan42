module Mis2
  class ActivityLog < ApplicationRecord
    self.table_name = "mis_activity_log"

    belongs_to :user, class_name: "Collavre::User"
  end
end
