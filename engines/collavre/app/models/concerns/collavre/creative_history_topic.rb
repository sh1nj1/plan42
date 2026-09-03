# frozen_string_literal: true

module Collavre
  module CreativeHistoryTopic
    extend ActiveSupport::Concern

    included do
      HISTORY_TOPIC_NAME = "History"
    end

    def history_topic(fallback_user: user)
      topics.find_or_create_by!(name: HISTORY_TOPIC_NAME) do |topic|
        topic.user = fallback_user
      end
    end
  end
end
