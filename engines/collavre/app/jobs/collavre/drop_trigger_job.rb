# frozen_string_literal: true

module Collavre
  class DropTriggerJob < ApplicationJob
    queue_as :default

    def perform(parent_creative_id, child_creative_id)
      parent = Creative.find_by(id: parent_creative_id)
      child = Creative.find_by(id: child_creative_id)
      return unless parent && child
      return unless parent.drop_trigger_enabled?

      # Agent is resolved from the parent (where the trigger is configured),
      # but the work happens on the child creative's chat
      agent = find_trigger_agent(parent)
      unless agent
        post_trigger_failure_notice(child, parent)
        return
      end

      # Create trigger topic and comment on the CHILD creative.
      # The comment's after_create_commit callback dispatches to orchestration
      # automatically — same path as a normal user comment.
      topic = find_or_create_trigger_topic(child, agent)

      # Idempotency: skip if a trigger comment already exists for this parent/child pair.
      # This prevents duplicate comments when SolidQueue retries a job after
      # after_create_commit succeeds but dispatch raises.
      return if already_triggered?(child, parent, topic)

      create_trigger_comment(child, parent, agent, topic)
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
      # System message (user: nil, skip_default_user: true) — not dispatched
      # to SystemEvents, so no AI agent will be triggered by this comment.
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

    def already_triggered?(child, parent, topic)
      trigger_key = I18n.t(
        "collavre.drop_trigger.child_entered",
        child_description: child.creative_snippet,
        child_id: child.id,
        parent_description: parent.creative_snippet
      )
      child.comments.where(topic_id: topic.id)
           .where("content LIKE ?", "%#{trigger_key.first(80)}%")
           .exists?
    end

    def create_trigger_comment(child, parent, agent, topic)
      trigger_text = I18n.t(
        "collavre.drop_trigger.child_entered",
        child_description: child.creative_snippet,
        child_id: child.id,
        parent_description: parent.creative_snippet
      )
      # Mention the agent to ensure exclusive routing via Matcher
      content = "@#{agent.name}: #{trigger_text}"
      child.comments.create!(
        content: content,
        topic_id: topic.id,
        private: false,
        user: child.user
      )
    end
  end
end
