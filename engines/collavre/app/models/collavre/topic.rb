module Collavre
  class Topic < ApplicationRecord
    self.table_name = "topics"

    belongs_to :creative, class_name: "Collavre::Creative"
    belongs_to :user, class_name: Collavre.configuration.user_class_name

    has_many :comments, class_name: "Collavre::Comment", dependent: :destroy

    validates :name, presence: true, uniqueness: { scope: :creative_id }

    before_create :set_default_position

    default_scope { order(:position) }

    private

    def set_default_position
      return if position_changed? && position != 0

      self.position = (Topic.unscoped.where(creative_id: creative_id).maximum(:position) || -1) + 1
    end
  end
end
