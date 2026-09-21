module Collavre
  class LlmModel < ApplicationRecord
    MAX_SUGGESTIONS = 100
    MAX_VENDOR_LENGTH = 255
    MAX_NAME_LENGTH = 255
    DEFAULT_SUGGESTIONS = [
      [ "cli_proxy", "paperclip/codex_custom/anthropic/claude-sonnet-4.5" ],
      [ "cli_proxy", "paperclip/codex_custom/openai/gpt-5" ]
    ].freeze

    self.table_name = "llm_models"

    belongs_to :creator,
               class_name: "Collavre::User",
               foreign_key: :created_by_id,
               optional: true,
               inverse_of: :created_llm_models

    normalizes :llm_vendor, with: ->(vendor) { vendor.to_s.strip.downcase }
    normalizes :name, with: ->(name) { name.to_s.strip }

    validates :llm_vendor, presence: true, length: { maximum: MAX_VENDOR_LENGTH }
    validates :name,
              presence: true,
              length: { maximum: MAX_NAME_LENGTH },
              uniqueness: { scope: :llm_vendor }

    scope :ordered, -> { order(:llm_vendor, :name) }
    scope :suggestions, -> {
      recent_ids = reorder(updated_at: :desc, id: :desc).limit(MAX_SUGGESTIONS).select(:id)
      where(id: recent_ids).ordered
    }

    def self.remember!(vendor:, name:, creator: nil)
      vendor = vendor.to_s.strip.downcase
      name = name.to_s.strip
      return if vendor.blank? || name.blank?

      model = find_or_create_by!(llm_vendor: vendor, name: name) do |record|
        record.creator = creator
      end
      model.touch unless model.previously_new_record?
      prune_excess!
      model
    rescue ActiveRecord::RecordNotUnique
      model = find_by!(llm_vendor: vendor, name: name)
      model.touch
      prune_excess!
      model
    end

    def self.seed_default_suggestions!
      DEFAULT_SUGGESTIONS.each { |vendor, name| remember!(vendor:, name:) }
    end

    def self.prune_excess!
      keep_ids = reorder(updated_at: :desc, id: :desc).limit(MAX_SUGGESTIONS).select(:id)
      where.not(id: keep_ids).delete_all
    end
    private_class_method :prune_excess!
  end
end
