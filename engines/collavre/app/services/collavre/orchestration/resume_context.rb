# frozen_string_literal: true

module Collavre
  module Orchestration
    # What a resumed turn is told about the attempt that was interrupted.
    #
    # A suspended turn is re-run from its trigger, and a session-backed agent is
    # sent only that trigger (SessionContextResolver#incremental_payload), so
    # anything the interrupted attempt already did has to travel inside the
    # trigger itself: why it stopped, the reply text the user has already seen,
    # and the actions recorded against the task. Without it the agent starts
    # over and repeats itself.
    #
    # Captured by TaskResumer.suspend! into the task payload under KEY, and
    # rendered in front of the trigger by both delivery paths — MessageBuilder
    # for LLM agents, ClaudeChannelAdapter for Claude Channel.
    module ResumeContext
      KEY = "resume_context"

      PARTIAL_REPLY_LIMIT = 4_000
      ACTION_LIMIT = 20

      # Bookkeeping entries that say nothing about what the turn accomplished.
      IGNORED_ACTION_TYPES = %w[start prompt_generated].freeze

      module_function

      # @return [Hash] the payload entry for a turn about to be suspended
      def capture(task, reason:)
        payload = task.trigger_event_payload || {}
        previous = payload[KEY].is_a?(Hash) ? payload[KEY] : {}

        {
          "reason" => reason.to_s,
          "attempt" => task.resume_count + 1,
          "trigger_comment_id" => previous["trigger_comment_id"] || payload.dig("comment", "id"),
          # An attempt that was cut off before writing anything keeps what an
          # earlier attempt had already shown, rather than forgetting it.
          "partial_reply" => partial_reply_text(task) || previous["partial_reply"],
          "actions" => action_summary(task)
        }.compact
      end

      # @return [String, nil] the note placed in front of a resumed trigger
      def render(context)
        data = context.is_a?(Hash) ? context[KEY] : nil
        return nil unless data.is_a?(Hash)

        scope = "collavre.orchestration.suspension"
        reason = I18n.t("#{scope}.resume_reasons.#{data['reason']}", default: data["reason"].to_s)
        sections = [ I18n.t("#{scope}.resume_context", reason: reason, attempt: data["attempt"] || 1).strip ]

        if data["partial_reply"].present?
          sections << "#{I18n.t("#{scope}.resume_partial_reply")}\n---\n#{data['partial_reply']}\n---"
        end

        actions = Array(data["actions"])
        if actions.any?
          sections << ([ I18n.t("#{scope}.resume_actions") ] + actions.map { |line| "- #{line}" }).join("\n")
        end

        sections.join("\n\n")
      end

      def prepend_to(text, context)
        note = render(context)
        note ? "#{note}\n\n#{text}" : text
      end

      def partial_reply_text(task)
        content = task.reply_comment&.content.to_s.strip
        return nil if content.empty? || content == Comment::STREAMING_PLACEHOLDER_CONTENT

        content.truncate(PARTIAL_REPLY_LIMIT)
      end

      def action_summary(task)
        lines = task.task_actions.where.not(action_type: IGNORED_ACTION_TYPES)
                    .order(:id).last(ACTION_LIMIT)
                    .map { |action| "#{action.action_type} (#{action.status})" }

        tool = task.pending_tool_call
        if tool.is_a?(Hash) && tool["tool_name"].present?
          lines << "tool #{tool['tool_name']} (#{tool['approved'] ? 'approved' : 'awaiting approval'})"
        end
        lines
      end
    end
  end
end
