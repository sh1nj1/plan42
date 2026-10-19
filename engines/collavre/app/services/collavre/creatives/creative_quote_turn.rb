# frozen_string_literal: true

module Collavre
  module Creatives
    # Resolves the document-mode quote (Comment#creative_quote?) that the
    # current agent write is answering, so AiWritePolicy can force a draft for a
    # "review" turn and refuse writes for a "question" turn.
    #
    # A native agent turn carries its task in Current.agent_turn. A delegated
    # MCP agent (e.g. Claude Channel) calls tools without a task, so its active
    # quote tasks are looked up by agent; a question among them wins, since a
    # write that slips through a question turn cannot be undone by approval.
    class CreativeQuoteTurn
      ACTIVE_STATUSES = %w[running delegated].freeze

      attr_reader :task, :comment

      def self.current
        task = Current.agent_turn&.dig(:task)
        return from_task(task) if task
        return unless Current.mcp_request && Current.user&.ai_user?

        from_mcp_agent(Current.user)
      end

      def self.from_task(task)
        comment = Comment.find_by(id: task.trigger_comment_id) if task.trigger_comment_id
        new(task, comment) if comment&.creative_quote?
      end

      def self.from_mcp_agent(agent)
        tasks = Task.where(agent_id: agent.id, status: ACTIVE_STATUSES)
                    .where(trigger_comment_id: Comment.where.not(quoted_creative_id: nil).select(:id))
                    .order(:id).to_a
        return if tasks.empty?

        comments = Comment.where(id: tasks.map(&:trigger_comment_id)).index_by(&:id)
        turns = tasks.map { |task| new(task, comments[task.trigger_comment_id]) }
        turns.find(&:question?) || turns.first
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

      def quoted_creative
        comment.quoted_creative
      end

      def read_only_result
        { success: false, error: I18n.t("collavre.comments.creative_quote.question_read_only") }
      end
    end
  end
end
