module Collavre
  class Topic < ApplicationRecord
    self.table_name = "topics"

    belongs_to :creative, class_name: "Collavre::Creative"
    belongs_to :user, class_name: Collavre.configuration.user_class_name

    has_many :comments, class_name: "Collavre::Comment", dependent: :destroy

    validates :name, presence: true, uniqueness: { scope: :creative_id }
  end
end
