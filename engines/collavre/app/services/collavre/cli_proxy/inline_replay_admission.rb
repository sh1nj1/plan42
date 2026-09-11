# frozen_string_literal: true

module Collavre
  module CliProxy
    # Revalidate at the point where a cancellable replay Task becomes visible.
    # All source rows stay locked until admission commits; provider I/O starts
    # only after these locks are released. Ordinary dispatches are unchanged.
    class InlineReplayAdmission
      def self.call(context, identity)
        return yield(context) unless identity

        # An earlier validation in this job may have populated the query cache.
        # Another connection's edits do not invalidate that cache.
        Task.uncached do
          with_locked_login(identity) do |login|
            yield ReplayClaims.attach(login.replay_payload, login.task.id)
          end
        end
      end

      # Early dispatch guards must release the login claim via the replay job.
      def self.reject!
        raise Client::Error.new(I18n.t("collavre.inline_agent_login.errors.cannot_retry"), status: 409, code: "cannot_retry")
      end

      def self.with_locked_login(identity)
        comment_id, user_id, task_id = identity
        task = Task.find(task_id)
        task.with_lock do
          comment = Comment.find(comment_id)
          raise ActiveRecord::RecordNotFound unless comment.task_id == task.id

          # Match admission's topic-before-comment order (including Main topics)
          # so a move/delete cannot slip between reading the source and creating
          # its Task. SQLite serializes the writes in this transaction instead.
          Orchestration::TopicSlot.lock!(task.topic_id, task.creative_id)
          lock_sources!(task.trigger_event_payload)
          yield InlineLogin.new(comment, User.find(user_id))
        end
      rescue ActiveRecord::RecordNotFound
        reject!
      end
      def self.lock_sources!(payload)
        anchor_id = payload.dig("comment", "id").to_i
        ids = Array(payload[Orchestration::TaskCoalescer::PAYLOAD_KEY]) + [ anchor_id ]
        # Lock even a currently withdrawn sibling: its concurrent update must
        # commit before validation, or wait until the replay Task is visible.
        # A single ID order avoids inversion when different turns share sources.
        sources = Comment.where(id: ids.compact.map(&:to_i).uniq).order(:id).lock.to_a
        reject! unless sources.any? { |source| source.id == anchor_id }
      end
      private_class_method :with_locked_login, :lock_sources!
    end
  end
end
