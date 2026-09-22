# frozen_string_literal: true

module Collavre
  module Onboarding
    # Proves that cleanup owns an item even after its session root is deleted.
    module Ownership
      def self.metadata(creative)
        data = creative&.data
        value = data.is_a?(Hash) ? data["onboarding"] : nil
        value.is_a?(Hash) ? value : {}
      end

      def self.stamp!(creative, session_id)
        onboarding = metadata(creative).merge(
          "session_id" => session_id,
          "ownership" => verifier.generate([ creative.user_id, creative.id, session_id ])
        )
        data = creative.data.is_a?(Hash) ? creative.data : {}
        creative.update!(data: data.merge("onboarding" => onboarding))
      end

      def self.owned?(creative)
        onboarding = metadata(creative)
        token = onboarding["ownership"]
        token.is_a?(String) && onboarding["session_id"].present? &&
          verifier.verified(token) == [ creative.user_id, creative.id, onboarding["session_id"] ]
      end

      def self.verifier
        Rails.application.message_verifier("collavre.onboarding.ownership")
      end
      private_class_method :verifier
    end
  end
end
