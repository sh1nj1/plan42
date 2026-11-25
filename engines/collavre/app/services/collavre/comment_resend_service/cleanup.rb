# frozen_string_literal: true

module Collavre
  class CommentResendService
    # Transaction records are finalized even when an earlier model callback raises.
    # Rails transfers this record to the parent transaction for nested commits.
    Cleanup = Data.define(:release) do
      def trigger_transactional_callbacks? = false

      def before_committed! = nil

      def committed!(**_options)
        # Cleanup must also run when Rails suppresses remaining model callbacks.
        release.call
      end

      def rolledback!(**_options) = nil
    end
  end
end
