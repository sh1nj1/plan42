class Creative < ApplicationRecord
    include Notifications

    has_many :subscribers, dependent: :destroy
    has_rich_text :description

    belongs_to :parent, class_name: "Creative", optional: true
    has_many :children, -> { order(:sequence) }, class_name: "Creative", foreign_key: :parent_id, dependent: :nullify

    validates :progress, numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0 }

    after_save :update_parent_progress
    after_destroy :update_parent_progress

    def self.recalculate_all_progress!
      Creative.where(parent_id: nil).find_each do |root|
        root.recalculate_subtree_progress!
      end
    end

    def recalculate_subtree_progress!
      children.each(&:recalculate_subtree_progress!)
      if children.any?
        update(progress: children.average(:progress) || 0)
      end
    end

    private

    def update_parent_progress
      return unless parent
      parent.update(progress: parent.children.average(:progress) || 0)
    end
end
