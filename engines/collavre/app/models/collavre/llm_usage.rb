# frozen_string_literal: true

module Collavre
  class LlmUsage < ApplicationRecord
    self.table_name = "llm_usages"
    TOKEN_FIELDS = %i[input_tokens output_tokens cache_read_tokens cache_write_tokens].freeze

    validates :event_key, :execution_id, :vendor, :model, :occurred_at, presence: true
    validates :measurement, inclusion: { in: %w[call run] }
    validates :requester_kind, inclusion: { in: %w[human joint unknown] }
    validates(*TOKEN_FIELDS, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true)

    after_create :index_requesters

    def self.requested_by(user_id)
      where(id: Requester.where(user_id: user_id).select(:llm_usage_id))
    end

    def self.visible_to(user)
      return none unless user
      return all if user.system_admin?

      where(owner_id: user.id).or(requested_by(user.id))
    end
    private

    def index_requesters
      return if requester_ids.empty?

      Requester.insert_all!(requester_ids.uniq.map { |user_id| { llm_usage_id: id, user_id: user_id } })
    end
  end
end
