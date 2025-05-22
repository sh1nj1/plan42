class Creative < ApplicationRecord
    include Notifications

    has_many :subscribers, dependent: :destroy
    has_one_attached :featured_image
    has_rich_text :description

    belongs_to :parent, class_name: "Creative", optional: true
    has_many :children, class_name: "Creative", foreign_key: :parent_id, dependent: :nullify

    validates :name, presence: true
    validates :inventory_count, numericality: { greater_than_or_equal_to: 0 }
end
