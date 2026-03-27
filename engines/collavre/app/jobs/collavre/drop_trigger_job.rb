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
      return unless agent

      # Create trigger topic and comment on the CHILD creative
      topic = find_or_create_trigger_topic(child, agent)
      comment = create_trigger_comment(child, parent, agent, topic)

      # Dispatch event targeting the child creative
      SystemEvents::Dispatcher.dispatch("comment_created", {
        "comment" => {
          "id" => comment.id,
          "content" => comment.content,
          "user_id" => comment.user_id,
          "from_ai" => false
        },
        "creative" => {
          "id" => child.id,
          "description" => child.description
        },
        "topic" => {
          "id" => topic.id
        },
        "chat" => {
          "content" => comment.content,
          "mentioned_user" => {
            "id" => agent.id,
            "name" => agent.name
          }
        },
        "drop_trigger" => {
          "parent_id" => parent.id,
          "parent_description" => parent.description
        }
      })
    end

    private

    def find_trigger_agent(creative)
      creative.all_shared_users(:feedback)
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
