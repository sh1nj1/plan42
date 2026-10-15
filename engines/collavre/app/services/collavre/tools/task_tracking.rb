# frozen_string_literal: true

module Collavre
  module Tools
    # Shared permission and bounded presentation rules for task read tools.
    module TaskTracking
      module_function

      def user!
        Current.user || raise(ArgumentError, I18n.t("collavre.tools.task_tracking.errors.current_user_required"))
      end

      def visible_comments(user)
        Comment.visible_to(user).without_approval_action
      end

      def effective_creative_id(task)
        task.creative_id || task.trigger_event_payload&.dig("creative", "id")&.to_i
      end

      def authorize_all!(tasks, user)
        ids = tasks.map { |task| effective_creative_id(task) }.uniq
        creatives = Creative.where(id: ids).index_by(&:id)
        triggers = visible_comments(user).where(id: tasks.filter_map(&:trigger_comment_id)).includes(:creative).index_by(&:id)
        (ids.map { |id| creatives[id] } + triggers.values.map(&:creative)).uniq.each do |creative|
          TopicAuthorizer.authorize_creative!(creative, :read, user: user)
        end
        tasks.each do |task|
          next if task.trigger_comment_id.nil?
          trigger = triggers[task.trigger_comment_id]
          raise PermissionDeniedError, I18n.t("collavre.tools.task_tracking.errors.unreadable_trigger") unless trigger
        end
      end

      def visible_tasks(scope, user, creative_id:)
        scope.where(trigger_comment_id: nil).or(
          scope.where(trigger_comment_id: visible_comments(user).where(creative_id: creative_id).select(:id))
        )
      end

      def describe_all(tasks, user)
        replies = visible_comments(user).where(task_id: tasks.map(&:id)).order(:id).group_by(&:task_id)
        tasks.map do |task|
          reply = replies[task.id]&.find { |comment| comment.creative_id == effective_creative_id(task) }
          describe(task, reply)
        end
      end

      def describe(task, reply)
        {
          task_id: task.id, name: task.name,
          agent: { id: task.agent_id, name: task.agent.display_name },
          status: task.status, active: task.active?,
          trigger_comment_id: task.trigger_comment_id,
          reply_comment_id: reply&.id,
          reply_summary: reply&.content&.then { |text| ActionController::Base.helpers.strip_tags(text).truncate(500) },
          suspend_reason: task.suspend_reason,
          created_at: task.created_at.iso8601, updated_at: task.updated_at.iso8601
        }
      end

      def invalid!(key)
        raise ArgumentError, I18n.t("collavre.tools.task_tracking.errors.#{key}")
      end
    end
  end
end
