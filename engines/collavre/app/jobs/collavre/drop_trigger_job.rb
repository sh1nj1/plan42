# frozen_string_literal: true

module Collavre
  class DropTriggerJob < ApplicationJob
    queue_as :default

    def perform(parent_creative_id, child_creative_id)
      parent = Creative.find_by(id: parent_creative_id)
      child = Creative.find_by(id: child_creative_id)
      return unless parent && child
      return unless parent.drop_trigger_enabled?

      agent = find_trigger_agent(parent)
      return unless agent

      topic = find_or_create_trigger_topic(parent, agent)
      comment = create_trigger_comment(parent, child, topic)

      SystemEvents::Dispatcher.dispatch("comment_created", {
        "comment" => {
          "id" => comment.id,
          "content" => comment.content,
          "user_id" => comment.user_id,
          "from_ai" => false
        },
        "creative" => {
          "id" => parent.id,
          "description" => parent.description
        },
        "topic" => {
          "id" => topic.id
        },
        "chat" => {
          "content" => comment.content
        },
        "drop_trigger" => {
          "child_id" => child.id,
          "child_description" => child.description
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

    def create_trigger_comment(parent, child, topic)
      content = I18n.t(
        "collavre.drop_trigger.child_entered",
        child_description: child.description,
        child_id: child.id,
        parent_description: parent.description
      )
      parent.comments.create!(
        content: content,
        topic_id: topic.id,
        private: false,
        user: parent.user
      )
    end
  end
end
