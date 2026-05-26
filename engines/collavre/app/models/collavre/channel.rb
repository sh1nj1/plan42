module Collavre
  class Channel < ApplicationRecord
    self.table_name = "channels"

    belongs_to :topic, class_name: "Collavre::Topic"

    enum :state, { active: 0, detached: 1 }, default: :active

    def handle(event:, payload:)
      raise NotImplementedError, "#{self.class} must implement #handle"
    end

    def detach!
      update!(state: :detached)
    end

    def record_event!(label:, link:)
      update!(latest_label: label, latest_link: link, last_event_at: Time.current)
    end

    def inject_into_topic!(injected_message)
      transaction do
        comment = topic.creative.comments.create!(
          user: injected_message.speaker,
          topic_id: topic.id,
          content: injected_message.message,
          private: false
        )
        record_event!(label: injected_message.label, link: injected_message.link)
        comment
      end
    end
  end
end
