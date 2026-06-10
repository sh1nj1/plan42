# frozen_string_literal: true

module Collavre
  module Orchestration
    # StuckDetector detects stuck tasks and creatives, then auto-escalates to admins.
    #
    # Detection conditions:
    # 1. Running tasks that haven't progressed for N minutes
    # 2. Tasks with too many retries (escalated but not handled)
    # 3. Creatives with no progress for extended periods
    #
    # Auto-escalation:
    # - Creates InboxItem for admin users
    # - Optionally creates a system comment
    #
    class StuckDetector
      # Result object for detection
      Result = Struct.new(:stuck_items, :escalated_count, keyword_init: true)

      # StuckItem represents a detected stuck item
      StuckItem = Struct.new(:type, :item, :reason, :stuck_since, :escalation_targets, keyword_init: true)

      def initialize(policy_resolver: nil)
        @policy_resolver = policy_resolver || PolicyResolver.new({})
      end

      # Run detection, auto-recovery, and escalation
      # Returns Result with stuck items and escalation count
      def detect_and_escalate
        config = stuck_detection_config
        return Result.new(stuck_items: [], escalated_count: 0) unless config["enabled"]

        stuck_items = []
        stuck_items.concat(detect_stuck_tasks(config))
        stuck_items.concat(detect_stalled_creatives(config))

        auto_recover_stuck_tasks(stuck_items)
        escalated_count = escalate_stuck_items(stuck_items, config)

        Result.new(stuck_items: stuck_items, escalated_count: escalated_count)
      end

      # Detect only (no escalation)
      def detect
        config = stuck_detection_config
        return [] unless config["enabled"]

        stuck_items = []
        stuck_items.concat(detect_stuck_tasks(config))
        stuck_items.concat(detect_stalled_creatives(config))
        stuck_items
      end

      private

      # Auto-recover stuck tasks by marking them as failed and draining the queue.
      def auto_recover_stuck_tasks(stuck_items)
        stuck_items.each do |stuck_item|
          next unless stuck_item.type == :task

          task = stuck_item.item
          next unless %w[running delegated].include?(task.status)

          task.update!(status: "failed")
          Rails.logger.info(
            "[StuckDetector] Auto-recovered task #{task.id} (agent=#{task.agent_id}): " \
            "marked as failed after #{((Time.current - stuck_item.stuck_since) / 60).round} minutes"
          )

          # Release resources held by the stuck task
          if task.agent
            tracker = ResourceTracker.for(task.agent)
            tracker.release!(task.id)
          end

          # If this was a workflow subtask, fail the parent so the workflow
          # advances instead of staying running with pending_creative_ids
          # pointing at a child that's been failed underneath it.
          if task.parent_task_id.present?
            begin
              Collavre::Comments::WorkflowExecutor.new(task.parent_task).fail_subtask!(
                task,
                error_message: "Auto-recovered: stuck for " \
                               "#{((Time.current - stuck_item.stuck_since) / 60).round} minutes"
              )
            rescue StandardError => e
              Rails.logger.error(
                "[StuckDetector] fail_subtask! failed for task #{task.id}: #{e.message}"
              )
            end
          end

          # Drain the queue for the topic so waiting tasks can execute
          AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
        rescue StandardError => e
          Rails.logger.error("[StuckDetector] Auto-recovery failed for task #{task.id}: #{e.message}")
        end
      end

      def stuck_detection_config
        @policy_resolver.resolve("stuck_detection")
      end

      # Detect tasks that are stuck in running state
      def detect_stuck_tasks(config)
        threshold_minutes = config["task_stuck_threshold_minutes"] || 30
        threshold_time = threshold_minutes.minutes.ago

        # Include delegated tasks: Claude Channel tasks sit in delegated
        # waiting for an external MCP reply; if the client disconnects, the
        # task can otherwise stay delegated forever and block the topic queue.
        stuck_tasks = Task.where(status: %w[running delegated])
                          .where("updated_at < ?", threshold_time)

        stuck_tasks.filter_map do |task|
          # Skip if already escalated recently
          next if recently_escalated?(task)

          escalation_targets = find_escalation_targets(task)
          next if escalation_targets.empty?

          StuckItem.new(
            type: :task,
            item: task,
            reason: :no_progress,
            stuck_since: task.updated_at,
            escalation_targets: escalation_targets
          )
        end
      end

      # Detect creatives that have stalled (no activity for extended period)
      def detect_stalled_creatives(config)
        threshold_minutes = config["creative_stall_threshold_minutes"] || 120
        threshold_time = threshold_minutes.minutes.ago

        # Find creatives with incomplete status but no recent activity
        # Only check creatives that have at least one AI agent with access
        stalled = []

        Creative.where("progress < 1.0")
                .where("updated_at < ?", threshold_time)
                .includes(creative_shares: :user)
                .find_each do |creative|
          # Skip if no AI agents have access
          ai_agents = creative.creative_shares
                              .reject { |s| s.permission == "no_access" }
                              .map(&:user)
                              .select(&:ai_user?)

          next if ai_agents.empty?

          # Skip if already escalated recently
          next if recently_escalated_creative?(creative)

          escalation_targets = find_creative_escalation_targets(creative)
          next if escalation_targets.empty?

          stalled << StuckItem.new(
            type: :creative,
            item: creative,
            reason: :stalled,
            stuck_since: creative.updated_at,
            escalation_targets: escalation_targets
          )
        end

        stalled
      end

      def find_escalation_targets(task)
        # Find admin users for the task's creative
        creative_id = task.trigger_event_payload&.dig("creative", "id")
        return [] unless creative_id

        creative = Creative.find_by(id: creative_id)
        return [] unless creative

        find_creative_escalation_targets(creative)
      end

      def find_creative_escalation_targets(creative)
        # Find users with admin permission on the creative or its ancestors
        ancestor_ids = [ creative.id ] + creative.ancestor_ids
        admin_users = CreativeShare.where(creative_id: ancestor_ids, permission: "admin")
                                   .includes(:user)
                                   .filter_map { |share| share.user unless share.user.ai_user? }

        # Also include the creative owner
        admin_users << creative.user if creative.user && !creative.user.ai_user?

        admin_users.uniq
      end

      def recently_escalated?(task)
        # Check if we've already escalated this task in the last hour
        cache_key = "stuck_detector:task:#{task.id}"
        Rails.cache.exist?(cache_key)
      end

      def recently_escalated_creative?(creative)
        cache_key = "stuck_detector:creative:#{creative.id}"
        Rails.cache.exist?(cache_key)
      end

      def mark_escalated(item)
        cache_key = case item.type
        when :task then "stuck_detector:task:#{item.item.id}"
        when :creative then "stuck_detector:creative:#{item.item.id}"
        end
        # Don't re-escalate for 1 hour
        Rails.cache.write(cache_key, true, expires_in: 1.hour)
      end

      def escalate_stuck_items(stuck_items, config)
        escalated_count = 0

        stuck_items.each do |stuck_item|
          escalated = escalate_item(stuck_item, config)
          if escalated
            mark_escalated(stuck_item)
            escalated_count += 1
          end
        end

        escalated_count
      end

      def escalate_item(stuck_item, config)
        stuck_item.escalation_targets.each do |target|
          create_inbox_notification(target, stuck_item)
        end

        # Optionally create a system comment
        if config["create_system_comment"] && stuck_item.type == :task
          create_system_comment(stuck_item)
        end

        true
      rescue StandardError => e
        Rails.logger.error("[StuckDetector] Failed to escalate: #{e.message}")
        false
      end

      def create_inbox_notification(owner, stuck_item)
        message_key, message_params = build_message(stuck_item)

        creative = case stuck_item.type
        when :task
                     creative_id = stuck_item.item.trigger_event_payload&.dig("creative", "id")
                     Creative.find_by(id: creative_id)
        when :creative
                     stuck_item.item
        end

        inbox_creative = Creative.inbox_for(owner)
        system_topic = inbox_creative.system_topic(fallback_user: owner)
        msg = I18n.t(message_key, **message_params.symbolize_keys, locale: owner.locale || "en")
        if creative
          creative_path = Collavre::Engine.routes.url_helpers.creative_path(creative, open_comments: true)
          msg += " [→](#{creative_path})"
        end
        Comment.create!(
          creative: inbox_creative,
          topic: system_topic,
          content: msg,
          user: nil,
          skip_default_user: true
        )
      end

      def build_message(stuck_item)
        case stuck_item.type
        when :task
          task = stuck_item.item
          minutes_stuck = ((Time.current - stuck_item.stuck_since) / 60).round

          [
            "collavre.stuck_detection.task_stuck",
            {
              task_name: task.name,
              agent_name: task.agent&.display_name || "Unknown",
              minutes: minutes_stuck
            }
          ]
        when :creative
          creative = stuck_item.item
          hours_stuck = ((Time.current - stuck_item.stuck_since) / 3600).round

          [
            "collavre.stuck_detection.creative_stalled",
            {
              creative_title: creative.creative_snippet,
              hours: hours_stuck,
              progress: ((creative.progress || 0) * 100).round
            }
          ]
        end
      end

      def create_system_comment(stuck_item)
        return unless stuck_item.type == :task

        task = stuck_item.item
        creative_id = task.trigger_event_payload&.dig("creative", "id")
        creative = Creative.find_by(id: creative_id)
        return unless creative

        topic_id = task.topic_id

        content = I18n.t(
          "collavre.stuck_detection.system_comment",
          task_name: task.name,
          agent_name: task.agent&.display_name || "Unknown"
        )

        Comment.create!(
          creative: creative,
          content: content,
          user: nil, # System comment
          topic_id: topic_id
        )
      end
    end
  end
end
