# frozen_string_literal: true

module Collavre
  module Orchestration
    module RestoredDispatchContext
      private

      def restored_context(payload, comment)
        TaskCoalescer.reanchor_payload(payload, comment).except(
          *CliProxy::ReplayClaims::KEYS, *DeliveryRecord::TURN_SCOPED_KEYS, *DeliveryRecord::DISPATCH_SCOPED_KEYS
        )
      end
    end
  end
end
