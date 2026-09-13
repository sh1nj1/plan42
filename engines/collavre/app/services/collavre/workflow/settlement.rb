# frozen_string_literal: true

module Collavre
  module Workflow
    class Settlement
      def initialize(execution)
        @execution = execution
      end

      def call
        @execution.chain.with_lock do
          next unless @execution.reload.open?
          error = Safety.new(@execution).reason
          error ? @execution.seal!(error) : settle_tasks
        end
      end

      def stop!(reason)
        @execution.chain.with_lock { @execution.seal!(reason) if @execution.reload.open? }
      end

      private

      def settle_tasks
        return unless @execution.handler == "agent"
        rows = @execution.admissions.order(:agent_id).to_a
        return if rows.empty?
        results = rows.map { |row| responder_result(row) }
        error = results.compact.find { |result| !%w[completed completed_no_anchor].include?(result) }
        return @execution.seal!(error) if error
        return if results.any?(&:nil?)
        return @execution.seal!("completed_no_anchor") if results.include?("completed_no_anchor")
        complete(rows)
      end

      def responder_result(row)
        task = row.task
        return row.reason if !task && row.state == "failed"
        return "delivery_failed" if !task && row.state == "completed"
        return unless task
        result = task.workflow_result(previous_reply_id: row.reply_comment_id)
        row.update!(reply_comment_id: task.reply_comment.id) if result == "completed"
        result
      end

      def complete(rows)
        return @execution.seal!("completed") unless @execution.emits
        return @execution.seal!("unknown_emit") unless SystemEvents::Vocabulary.known?(@execution.emits)
        depth = @execution.context.dig("event", "depth")
        error = @execution.chain.depth_reason(depth + 1)
        return @execution.seal!(error) if error
        context = ChildContext.new(@execution, rows).build
        error = EnvelopeValidation.reason(context)
        return @execution.seal!(error) if error
        @execution.outboxes.create!(key: "child", context: context, due_at: Time.current)
        @execution.seal!("completed")
      end
    end
  end
end
