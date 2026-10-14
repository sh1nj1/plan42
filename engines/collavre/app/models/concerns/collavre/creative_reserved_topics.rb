module Collavre
  module CreativeReservedTopics
    # Find or create the "System" topic for this inbox creative.
    # Re-creates it if the user deletes it.
    def system_topic(fallback_user: user)
      find_or_create_reserved_topic(Creative::SYSTEM_TOPIC_NAME, fallback_user)
    end

    def main_topic(fallback_user: user)
      find_or_create_reserved_topic(Creative::MAIN_TOPIC_NAME, fallback_user)
    end

    private

    def find_or_create_reserved_topic(name, owner)
      topics.find_by(name: name) || self.class.transaction(requires_new: true) do
        topics.create!(name: name, user: owner)
      end
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      # Another client may recreate the topic between lookup and insert.
      # Preserve unrelated validation failures when no competing topic exists.
      topics.find_by(name: name) || raise
    end
  end
end
