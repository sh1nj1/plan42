module Collavre
  class CreativeSharesCache < ApplicationRecord
    self.table_name = "creative_shares_caches"
    self.record_timestamps = false

    belongs_to :creative, class_name: "Collavre::Creative"
    belongs_to :user, class_name: Collavre.configuration.user_class_name, optional: true
    belongs_to :source_share, class_name: "Collavre::CreativeShare", optional: true

    enum :permission, {
      no_access: 0,
      read: 1,
      feedback: 2,
      write: 3,
      admin: 4
    }
  end
end
