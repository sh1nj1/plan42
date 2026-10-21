# frozen_string_literal: true

module Collavre
  module Creatives
    # Resolves the document-mode quote (Comment#creative_quote?) that the
    # current agent write is answering, so AiWritePolicy can force a draft for a
    # "review" turn and refuse writes for a "question" turn.
    #
    # A native agent turn carries its task in Current.agent_turn. A delegated
    # agent calling /mcp or the bearer attachment endpoint names its task with
    # the X-Collavre-Task header (Current.mcp_task_id); the task must belong to
    # that agent and still be active. Without the header the write is matched to
    # the agent's only active task. When the agent has several active tasks and
    # one of them is a quote, the write cannot be tied to the right draft (or
    # kept out of a question), so it is refused until the task is named.
    class CreativeQuoteTurn
      ACTIVE_STATUSES = %w[running delegated].freeze
      TASK_HEADER = "X-Collavre-Task"

      # Returned when a delegated write cannot be tied to one task.
      class Unresolved
        def initialize(error_key)
          @error_key = error_key
        end

        def task = nil
        def review? = false
        def write_blocked? = true

        def blocked_result
          { success: false, error: I18n.t("collavre.comments.creative_quote.#{@error_key}", header: TASK_HEADER) }
        end
      end

      attr_reader :task, :comment

      def self.current(external_request: false)
        task = Current.agent_turn&.dig(:task)
        return from_task(task) if task
        return unless Current.mcp_request || external_request

        agent = delegated_agent
        from_delegated_agent(agent, Current.mcp_task_id) if agent
      end

      def self.delegated_agent
        Current.mcp_agent_workspace&.agent || (Current.user if Current.user&.ai_user?)
      end

      def self.from_task(task)
        comment = Comment.find_by(id: task.trigger_comment_id) if task.trigger_comment_id
        new(task, comment) if comment&.creative_quote?
      end

      def self.from_delegated_agent(agent, task_id)
        active = Task.where(agent_id: agent.id, status: ACTIVE_STATUSES)
        if task_id.present?
          task = active.find_by(id: task_id)
          return task ? from_task(task) : Unresolved.new(:task_not_active)
        end

        quote_comment_ids = Comment.where.not(quoted_creative_id: nil).select(:id)
        return unless active.where(trigger_comment_id: quote_comment_ids).exists?

        tasks = active.limit(2).to_a
        tasks.one? ? from_task(tasks.first) : Unresolved.new(:task_ambiguous)
      end

      def initialize(task, comment)
        @task = task
        @comment = comment
      end

      def question?
        comment.creative_question_message?
      end

      def review?
        comment.creative_review_message?
      end

      # A document-mode "question" only answers; it must never write.
      def write_blocked?
        question?
      end

      def quoted_creative
        comment.quoted_creative
      end

      def blocked_result
        { success: false, error: I18n.t("collavre.comments.creative_quote.question_read_only") }
      end
    end
  end
end
