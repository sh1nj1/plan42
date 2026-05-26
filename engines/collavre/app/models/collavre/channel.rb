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
  end
end
