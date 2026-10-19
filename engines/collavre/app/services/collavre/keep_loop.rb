# frozen_string_literal: true

module Collavre
  # Identity checks share one contract. Callers hold topic -> creative locks
  # across admission and writes, and separately check their allowed states.
  module KeepLoop
    module_function

    # Approval continuations resume the loop turn whose agent asked for approval.
    CONTINUATION_KEY = "loop_continuation"
    # Marks the asking turn whose completion the continuation now owns.
    CONTINUED_KEY = "loop_continued"
    TURN_EVENTS = %w[comment_created async_approval claude_channel_approval].freeze

    def admit!(creative, generation:, comment_id:)
      config = creative.data&.dig("trigger", "loop") || {}
      config["source"] == "keep" && generation.is_a?(Integer) && generation.positive? &&
        config["generation"] == generation && config["current_comment_id"] == comment_id
    end

    def task?(creative, task)
      comment_id = creative.data.dig("trigger", "loop", "current_comment_id")
      payload = task.trigger_event_payload || {}
      return false unless comment_id && loop_comment_ids(payload).include?(comment_id)

      generation = payload.dig(Orchestration::KeepDispatchRestoration::KEY, comment_id.to_s) ||
        payload.dig("comment", "keep_loop_generation") || payload.dig(CONTINUATION_KEY, "generation")
      admit!(creative, generation: generation, comment_id: comment_id)
    end

    # Comment turns and approval continuations that inherited a turn's identity.
    def turn?(task)
      task.trigger_event_name == "comment_created" ||
        (task.trigger_event_name.in?(TURN_EVENTS) && (task.trigger_event_payload || {}).key?(CONTINUATION_KEY))
    end

    def turn_generation(payload)
      payload&.dig("comment", "keep_loop_generation") || payload&.dig(CONTINUATION_KEY, "generation")
    end

    def loop_comment_ids(payload)
      ([ payload.dig("comment", "id"), payload.dig(CONTINUATION_KEY, "comment_id") ] +
        Array(payload[Orchestration::TaskCoalescer::PAYLOAD_KEY]) +
        Array(payload[Orchestration::DeliveryRecord::DROPPED_KEY])).compact.map(&:to_i)
    end

    def with_dispatch(context)
      generation = context&.dig("comment", "keep_loop_generation")
      return yield unless dispatch?(context)

      result = :rejected
      Comments::TopicMutation.call(context.dig("topic", "id"), context.dig("creative", "id")) do
        creative = Creative.find_by(id: context.dig("creative", "id"))
        next unless creative

        creative.with_lock do
          next unless creative.data&.dig("trigger", "loop", "state") == "running"
          next unless admit!(creative, generation: generation, comment_id: context.dig("comment", "id"))

          result = yield
        end
      end
      result
    end

    def dispatch?(context)
      return true if context&.fetch("comment", {})&.key?("keep_loop_generation")

      config = Creative.where(id: context&.dig("creative", "id")).pick(:data)&.dig("trigger", "loop")
      config && config["source"] == "keep" && config["current_comment_id"] == context&.dig("comment", "id")
    end

    # The counter outlives loop deletion, preventing identity reuse. Invoke
    # inside the same creative transaction that starts or controls the loop.
    def next_generation!(data)
      trigger = data["trigger"] ||= {}
      value = [ trigger.fetch("keep_generation", 0).to_i, trigger.dig("loop", "generation").to_i ].max + 1
      trigger["keep_generation"] = value
      trigger.delete("keep_queued_dispatches")
      trigger.delete("keep_loop_recovery")
      value
    end
  end
end
