# frozen_string_literal: true

module Collavre
  class Creative < ApplicationRecord
    module AiWritePolicy
      extend ActiveSupport::Concern

      POLICIES = %w[auto review].freeze
      DEFAULT_POLICY = "auto"

      def effective_ai_write_policy(visited_ids = Set.new)
        return DEFAULT_POLICY if visited_ids.include?(id)

        visited_ids.add(id)
        own_policy = data&.dig("ai_write_policy").to_s
        return own_policy if own_policy.in?(POLICIES)

        parent&.effective_ai_write_policy(visited_ids) || DEFAULT_POLICY
      end

      def ai_write_review?
        effective_ai_write_policy == "review"
      end
    end
  end
end
