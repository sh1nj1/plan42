# frozen_string_literal: true

module Collavre
  class DropTriggerJob < ApplicationJob
    queue_as :default

    # Custom error raised when dispatch returns no scheduled agents.
    # This triggers retry_on instead of silently succeeding.
    class DispatchFailedError < StandardError; end

    retry_on DispatchFailedError, wait: 5.seconds, attempts: 3

    # End-to-end idempotent: safe to retry at any point.
    #
    # 1. Find or create trigger comment (no duplicates)
    # 2. Check if dispatch already succeeded (Task exists)
    # 3. Dispatch explicitly if needed (not via after_create_commit)
    #
    # This avoids the failure mode where:
    #   - Comment is created (committed)
    #   - after_create_commit dispatch fails
    #   - Retry skips everything because comment already exists
    def perform(parent_creative_id, child_creative_id)
      parent = Creative.find_by(id: parent_creative_id)
      child = Creative.find_by(id: child_creative_id)
      return unless parent && child
      return unless parent.drop_trigger_enabled?

      agent = find_trigger_agent(parent)
      unless agent
        post_trigger_failure_notice(child, parent)
        return
      end

      topic = find_or_create_trigger_topic(child, agent)

      # Initialize trigger loop state on the child creative
      initialize_trigger_loop(child)

      # Step 1: Find existing or create new trigger comment (idempotent)
      comment = find_trigger_comment(child, parent, topic) ||
                create_trigger_comment(child, parent, agent, topic)

      # Step 2: Skip if dispatch already produced a Task for this comment
      return if task_exists_for?(comment)

      # Step 3: Dispatch explicitly
      dispatch_trigger(comment)
    rescue StandardError => e
      Rails.logger.error(
        "[DropTriggerJob] Failed for parent=#{parent_creative_id} child=#{child_creative_id}: " \
        "#{e.class} #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
      )
      raise
    end

    private

    def post_trigger_failure_notice(child, parent)
      topic = child.topics.find_or_create_by!(name: "Drop Trigger") do |t|
        t.user = child.user
      end
      post_system_notice(child, topic, I18n.t(
        "collavre.drop_trigger.no_agent",
        parent_description: parent.creative_snippet
      ))
    end

    def post_system_notice(child, topic, content)
      child.comments.create!(
        content: content,
        topic_id: topic.id,
        private: false,
        skip_default_user: true
      )
    end

    def find_trigger_agent(creative)
      creative.all_shared_users(:write)
              .map(&:user)
              .find(&:ai_user?)
    end

    def find_or_create_trigger_topic(creative, agent)
      topic = creative.topics.find_by(name: "Drop Trigger")
      return topic if topic

      topic = creative.topics.create!(
        name: "Drop Trigger",
        user: creative.user
      )
      topic.set_primary_agent!(agent)
      topic
    end

    def trigger_content_key(child, parent)
      I18n.t(
        "collavre.drop_trigger.child_entered",
        child_description: child.creative_snippet,
        child_id: child.id,
        parent_description: parent.creative_snippet
      )
    end

    def find_trigger_comment(child, parent, topic)
      key = trigger_content_key(child, parent)
      child.comments.where(topic_id: topic.id)
           .where("content LIKE ?", "%#{key.first(80)}%")
           .first
    end

    def create_trigger_comment(child, parent, agent, topic)
      trigger_text = trigger_content_key(child, parent)
      loop_instructions = I18n.t("collavre.trigger_loop.instructions")
      content = "@#{agent.name}: #{trigger_text}\n\n#{loop_instructions}"
      # skip_dispatch: true — we dispatch explicitly in Step 3,
      # not via after_create_commit, so retries can re-attempt dispatch
      # even when the comment already exists.
      child.comments.create!(
        content: content,
        topic_id: topic.id,
        private: false,
        user: child.user,
        skip_dispatch: true
      )
    end

    def initialize_trigger_loop(child)
      data = child.data || {}
      trigger = data["trigger"] || {}

      # Only initialize if loop doesn't exist yet
      return if trigger["loop"].present?

      trigger["loop"] = {
        "state" => "running",
        "current_iteration" => 0,
        "max_iterations" => 10,
        "completion_conditions" => [],
        "stuck_conditions" => [],
        "on_retry" => "continue",
        "last_task_id" => nil,
        "cooldown_seconds" => 10
      }
      data["trigger"] = trigger
      child.update!(data: data)
    end

    def task_exists_for?(comment)
      comment_id_str = comment.id.to_s
      Task.where(creative_id: comment.creative_id, topic_id: comment.topic_id)
          .where.not(status: "cancelled")
          .find_each do |t|
        return true if t.trigger_event_payload&.dig("comment", "id").to_s == comment_id_str
      end
      false
    end

    def dispatch_trigger(comment)
      # Use Comment#dispatch_payload — single source of truth shared with
      # the after_create_commit callback, preventing payload drift.
      scheduled_agents = SystemEvents::Dispatcher.dispatch(
        "comment_created", comment.dispatch_payload
      )

      if scheduled_agents.blank?
        raise DispatchFailedError,
          "Dispatch returned no agents for comment #{comment.id} " \
          "(creative=#{comment.creative_id}, topic=#{comment.topic_id})"
      end
    end
  end
end
