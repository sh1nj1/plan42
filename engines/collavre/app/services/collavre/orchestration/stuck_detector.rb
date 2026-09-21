# frozen_string_literal: true

module Collavre
  module Orchestration
    # StuckDetector detects stuck tasks, auto-recovers them, and escalates to admins.
    #
    # Detection conditions:
    # 1. Running tasks that haven't progressed for N minutes
    # 2. Tasks with too many retries (escalated but not handled)
    #
    # Auto-escalation:
    # - Creates inbox comments for admin users
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
        stuck_items.concat(detect_orphaned_queued_tasks(config))

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
        stuck_items.concat(detect_orphaned_queued_tasks(config))
        stuck_items
      end

      private

      # Auto-recover stuck items: fail-and-drain for live tasks, self-heal for
      # orphaned queued waiters.
      def auto_recover_stuck_tasks(stuck_items)
        stuck_items.each do |stuck_item|
          case stuck_item.type
          when :task          then recover_stuck_task(stuck_item)
          when :queued_orphan then recover_orphaned_queued_task(stuck_item)
          end
        end
      end

      # Self-heal an orphaned queued waiter: its blocker is gone but it was never
      # drained (missed dequeue / enqueue-vs-terminate TOCTOU race / lost
      # cross-process broadcast). Re-check liveness atomically, then drain.
      def recover_orphaned_queued_task(stuck_item)
        task = stuck_item.item.reload
        return unless task.status == "queued"

        # If the topic is back at capacity since detection, the normal terminal
        # callback will drain the queue when a slot frees — leave it alone. This
        # check also bounds promotions across one detection cycle: dequeue moves
        # a waiter queued -> pending synchronously, which occupying_topic_slot
        # counts, so consecutive orphans each fill exactly one free slot until the
        # topic is full. With topic_max_concurrent_jobs > 1 and several free slots
        # all are filled this cycle; a per-topic dedupe would instead leave every
        # waiter past the first orphaned until the next run.
        return if topic_at_capacity?(task)

        Rails.logger.info(
          "[StuckDetector] Self-healing orphaned queued task #{task.id} " \
          "(topic=#{task.topic_id}, creative=#{task.creative_id}): no live blocker, draining queue"
        )
        AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
      rescue StandardError => e
        Rails.logger.error("[StuckDetector] Self-heal failed for queued task #{stuck_item.item.id}: #{e.message}")
      end

      # Whether a topic holds no free concurrency slot for a queued waiter.
      # Compares occupied slots against topic_max (the scheduler's admission rule)
      # rather than treating any single live blocker as full capacity — otherwise,
      # with topic_max_concurrent_jobs > 1, a missed dequeue would leave the waiter
      # suppressed until the *last* blocker terminates instead of the moment a slot
      # frees up. Occupancy counts pending as well as running/delegated: a waiter
      # that a prior dequeue already claimed sits in "pending" until its AiAgentJob
      # starts, and the detector fires precisely on the backed-up condition where
      # that window is wide — counting only running/delegated would see a free slot
      # and promote a second waiter into a slot that is already claimed (double
      # dequeue). This is intentionally stricter than the scheduler's reactive
      # check; being stricter can only suppress recovery, never over-admit. When no
      # topic limit is configured the scheduler never defers, so fall back to the
      # conservative "any occupied slot" check.
      def topic_at_capacity?(task)
        topic_max = scheduling_resolver_for(task).topic_max_concurrent_jobs
        occupied_count = Task.occupying_topic_slot(task.topic_id, task.creative_id).count
        return occupied_count.positive? unless topic_max

        occupied_count >= topic_max
      end

      # Resolve scheduling policy against the queued task's own topic/creative
      # context — the same context the scheduler used to admit it. The detector's
      # default resolver is built with an empty context (it only needs the global
      # stuck_detection policy), so reading topic_max_concurrent_jobs off it would
      # see only the global default and ignore any topic-/creative-scoped override.
      # That mismatch would violate a topic's serialization when its scoped limit
      # is below the global value, or wrongly suppress recovery when it is above.
      def scheduling_resolver_for(task)
        context = {}
        context["creative"] = { "id" => task.creative_id } if task.creative_id
        context["topic"] = { "id" => task.topic_id } if task.topic_id
        PolicyResolver.new(context)
      end

      # Fail a stuck running/delegated task and drain the topic queue.
      def recover_stuck_task(stuck_item)
        task = stuck_item.item
        return unless %w[running delegated].include?(task.status)

        recovered = if task.status == "running"
          DeliveryRecord.fail_while_worker_settles!(task)
        else
          task.update!(status: "failed")
          true
        end
        return unless recovered

        Rails.logger.info(
          "[StuckDetector] Auto-recovered task #{task.id} (agent=#{task.agent_id}): " \
          "marked as failed after #{((Time.current - stuck_item.stuck_since) / 60).round} minutes"
        )

        # Release resources held by the stuck task
        if task.agent
          tracker = ResourceTracker.for(task.agent)
          tracker.release!(task.id)
        end

        # Drain the queue for the topic so waiting tasks can execute
        AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
      rescue StandardError => e
        Rails.logger.error("[StuckDetector] Auto-recovery failed for task #{stuck_item.item.id}: #{e.message}")
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

      # Detect orphaned queued waiters: tasks left in "queued" for a topic that
      # holds no occupied slot (no running/delegated blocker and no pending claim).
      # A queued task's only path to
      # execution is dequeue_next_for_topic, which fires when the blocker reaches
      # a terminal status. If that single hand-off is missed — an
      # enqueue-vs-terminate TOCTOU race, or a lost cross-process broadcast — the
      # blocker is already gone and nothing will ever wake the waiter: it shows
      # "⏳" waiting notice forever. These are invisible to detect_stuck_tasks, which only
      # scans running/delegated. There is no stop button to press here because the
      # blocker no longer exists; the fix is to drain the queue (see
      # recover_orphaned_queued_task), not to escalate.
      def detect_orphaned_queued_tasks(config)
        threshold_minutes = config["queued_orphan_threshold_minutes"] || 5
        threshold_time = threshold_minutes.minutes.ago

        Task.where(status: "queued")
            .where("updated_at < ?", threshold_time)
            .filter_map do |task|
          # Only orphaned if the topic has a free slot. A waiter is legitimately
          # queued while the topic is at capacity.
          next if topic_at_capacity?(task)

          StuckItem.new(
            type: :queued_orphan,
            item: task,
            reason: :orphaned_waiter,
            stuck_since: task.updated_at,
            escalation_targets: []
          )
        end
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
                                   .filter_map { |share| share.user if share.user && !share.user.ai_user? }

        # Also include the creative owner
        admin_users << creative.user if creative.user && !creative.user.ai_user?

        admin_users.uniq
      end

      def recently_escalated?(task)
        # Check if we've already escalated this task in the last hour
        cache_key = "stuck_detector:task:#{task.id}"
        Rails.cache.exist?(cache_key)
      end

      def mark_escalated(item)
        # Don't re-escalate for 1 hour
        Rails.cache.write("stuck_detector:task:#{item.item.id}", true, expires_in: 1.hour)
      end

      def escalate_stuck_items(stuck_items, config)
        escalated_count = 0

        stuck_items.each do |stuck_item|
          # Orphaned queued waiters are silently self-healed (queue drained),
          # not escalated to admins — there is no human action to take.
          next if stuck_item.type == :queued_orphan

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
        create_system_comment(stuck_item) if config["create_system_comment"]

        true
      rescue StandardError => e
        Rails.logger.error("[StuckDetector] Failed to escalate: #{e.message}")
        false
      end

      def create_inbox_notification(owner, stuck_item)
        message_key, message_params = build_message(stuck_item)

        creative_id = stuck_item.item.trigger_event_payload&.dig("creative", "id")
        creative = Creative.find_by(id: creative_id)

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
      end

      def create_system_comment(stuck_item)
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
