module Collavre
  class LlmModel < ApplicationRecord
    self.table_name = "llm_models"

    belongs_to :creator,
               class_name: "Collavre::User",
               foreign_key: :created_by_id,
               optional: true,
               inverse_of: :created_llm_models

    normalizes :llm_vendor, with: ->(vendor) { vendor.to_s.strip.downcase }
    normalizes :name, with: ->(name) { name.to_s.strip }

    validates :llm_vendor, presence: true
    validates :name, presence: true, uniqueness: { scope: :llm_vendor }

    scope :ordered, -> { order(:llm_vendor, :name) }

    def self.remember!(vendor:, name:, creator: nil)
      vendor = vendor.to_s.strip.downcase
      name = name.to_s.strip
      return if vendor.blank? || name.blank?

      find_or_create_by!(llm_vendor: vendor, name: name) do |model|
        model.creator = creator
      end
    rescue ActiveRecord::RecordNotUnique
      find_by!(llm_vendor: vendor, name: name)
    end
  end
end
