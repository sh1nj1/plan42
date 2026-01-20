class CreativeSharesCache < ApplicationRecord
  self.record_timestamps = false

  belongs_to :creative
  belongs_to :user, optional: true
  belongs_to :source_share, class_name: "CreativeShare", optional: true

  enum :permission, {
    no_access: 0,
    read: 1,
    feedback: 2,
    write: 3,
    admin: 4
  }
end
