# frozen_string_literal: true

module Collavre
  class CommentResendService
    class NotAllowed < StandardError; end

    COPY_ATTRIBUTES = %w[content private approver_id review_type quoted_comment_id quoted_text].freeze

    # Command results are appended to content; skip_dispatch is not persisted.
    # Reject slash-prefixed messages without executing commands to identify them.
    def self.command_message?(comment)
      comment.content.to_s.strip.start_with?("/")
    end

    def initialize(comment:, user:)
      @comment = comment
      @user = user
      @creative = comment.creative
      @topic_id = comment.topic_id
    end

    def call
      applied = Comments::TopicMutation.call(@topic_id, @creative.id) do
        @comment.lock!
        validate!
        # Register before saving the replacement so the old session is aborted before dispatch.
        Comment.connection.add_transaction_record(Cleanup.new(-> { @cancelled_tasks.each { |task, status| release_task(task, status) } }))
        replace!
      end
      raise NotAllowed unless applied

      @replacement
    end

    private

    def validate!
      raise NotAllowed unless @comment.user_id == @user.id && !@user.ai_user?
      raise NotAllowed unless @comment.creative_id == @creative.id && @comment.topic_id == @topic_id
      raise NotAllowed unless @creative.has_permission?(@user, :feedback)
      raise NotAllowed if @creative.reload.archived? || @comment.approval_action?
      raise NotAllowed if @comment.private? || self.class.command_message?(@comment)
      validate_topic!
    end

    def validate_topic!
      topic = @comment.topic&.reload
      raise NotAllowed if topic&.archived? || topic&.history?
      raise NotAllowed if @creative.inbox? && topic&.name == Creative::SYSTEM_TOPIC_NAME
      raise NotAllowed if @creative.github_markdown? && topic&.name == Creative::CONTENT_TOPIC_NAME
    end

    def replace!
      replies = @creative.comments.where(topic_id: @topic_id).visible_to(@user)
                         .where(user_id: Collavre.user_class.ai_agents.select(:id))
                         .where("comments.id > ?", @comment.id)
                         .order(:id).lock.to_a
      removed = [ @comment, *replies ]
      @cancelled_tasks = cancel_reply_tasks(replies)
      @replacement = @creative.comments.build(@comment.attributes.slice(*COPY_ATTRIBUTES))
      @replacement.assign_attributes(user: @user, topic_id: @topic_id)
      @replacement.quoted_comment_id = nil if removed.any? { |c| c.id == @replacement.quoted_comment_id }
      @replacement.images.attach(@comment.images.map(&:blob))
      # Quoting comments otherwise cascade-delete, including other people's messages.
      Comment.where(quoted_comment_id: removed.map(&:id)).update_all(quoted_comment_id: nil)
      removed.each(&:destroy!)
      cancel_source_tasks
      @replacement.save!
    end

    def cancel_source_tasks
      Task.where(status: Task::ACTIVE_STATUSES).find_each do |task|
        status = @comment.cancel_task_for_withdrawn_source(task)
        @cancelled_tasks << [ task, status ] if status
      end
    end

    def cancel_reply_tasks(replies)
      Task.where(id: replies.filter_map(&:task_id)).filter_map do |task|
        status = task.cancel_if_active!
        [ task, status ] if status
      end
    end

    def abort_context(task)
      # The source row is gone; retain the task's original topic for session keys.
      @comment.dup.tap { |comment| comment.assign_attributes(creative_id: task.creative_id, topic_id: task.topic_id) }
    end

    def release_task(task, status)
      AgentSessionAbort.call(agent: task.agent, task: task, creative: task.creative, comment: abort_context(task))
      Comment.remove_waiter_notices!(creative_id: task.creative_id, topic_id: task.topic_id, task_ids: task.id)
      Comment.remove_stranded_waiting_notices!(creative_id: task.creative_id, topic_id: task.topic_id)
      if Task::HELD_SLOT_WITHOUT_WORKER.include?(status)
        Orchestration::ResourceTracker.for(task.agent).release!(task.id)
        Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
      end
    end
  end
end
