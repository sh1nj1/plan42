# frozen_string_literal: true

module Collavre
  class Comment
    # A "⏸️" notice Orchestration::TaskResumer posts when it sets a turn aside.
    # It names that turn in waiting_notice_task_id so the notice can carry the
    # turn's Stop control while it waits: the turn's own reply is gone or
    # detached by then, and task_id is Task#reply_comment's key.
    module SuspensionNotice
      SCOPE = "suspension"

      # The suspended turn this notice announced, while it is still suspended.
      def self.turn_for(comment)
        return unless comment.waiting_notice_scope == SCOPE && comment.waiting_notice_task_id

        Collavre::Task.suspended.find_by(id: comment.waiting_notice_task_id)
      end
    end
  end
end
