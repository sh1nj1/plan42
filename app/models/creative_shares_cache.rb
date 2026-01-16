class CreativeSharesCache < ApplicationRecord
  belongs_to :creative
  belongs_to :user, optional: true
  belongs_to :source_share, class_name: "CreativeShare"

  enum :permission, {
    no_access: 0,
    read: 1,
    feedback: 2,
    write: 3,
    admin: 4
  }
end
