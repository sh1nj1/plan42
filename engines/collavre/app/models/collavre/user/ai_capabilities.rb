# frozen_string_literal: true

module Collavre
  class User
    module AiCapabilities
      extend ActiveSupport::Concern

      included do
        after_update :release_non_chat_primary_pins, if: :saved_change_to_llm_vendor?
      end

      def supports?(capability)
        ai_user? && AiClient.supports?(llm_vendor, capability, model: llm_model.to_s)
      end

      private

      def release_non_chat_primary_pins
        return if supports?(:chat)

        Topic.where(primary_agent_id: id, session_id: nil).update_all(primary_agent_id: nil, updated_at: Time.current)
      end

      class_methods do
        def chat_capable
          vendors = AiClient.vendor_capabilities.keys.reject { |vendor| AiClient.supports?(vendor, :chat) }
          vendors.empty? ? all : where("llm_vendor IS NULL OR LOWER(TRIM(llm_vendor)) NOT IN (?)", vendors)
        end
      end
    end
  end
end
