module Collavre
  class Label < ApplicationRecord
    self.table_name = "labels"
    # Use short class names for STI to avoid namespace issues during hot reload
    self.store_full_sti_class = false

    has_many :tags, class_name: "Collavre::Tag", dependent: :destroy
    belongs_to :owner, class_name: Collavre.configuration.user_class_name, optional: true
    belongs_to :creative, class_name: "Collavre::Creative", optional: false

    delegate :description, to: :creative, allow_nil: true
    alias_method :name, :description

    # STI: Plan, Version, etc subclasses use type column
    # creative_id, value, target_date etc attributes included

    # Resolve short STI class names to namespaced versions
    def self.find_sti_class(type_name)
      type_name = "Collavre::#{type_name}" unless type_name.start_with?("Collavre::")
      super(type_name)
    end

    after_create :create_auto_tag

    # Check if user has permission to read this label
    # If linked to a Creative, delegates to Creative's permission system
    # Otherwise falls back to owner-based or public (nil owner) visibility
    def readable_by?(user)
      return true if owner_id.present? && owner_id == user&.id

      if creative_id.present? && creative
        creative.has_permission?(user, :read)
      else
        owner_id.nil?
      end
    end

    private

    def create_auto_tag
      return unless creative_id.present?

      tags.create!(creative_id: creative_id)
    end
  end
end
