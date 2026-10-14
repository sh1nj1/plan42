# frozen_string_literal: true

module Collavre
  class User
    module AiCapabilities
      extend ActiveSupport::Concern

      def supports?(capability)
        ai_user? && AiClient.supports?(llm_vendor, capability)
      end

      class_methods do
        def chat_capable
          vendors = AiClient.vendor_options.map(&:last).reject { |vendor| AiClient.supports?(vendor, :chat) }
          vendors.empty? ? all : where("llm_vendor IS NULL OR llm_vendor NOT IN (?)", vendors)
        end
      end
    end
  end
end
