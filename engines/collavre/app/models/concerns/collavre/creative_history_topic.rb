# frozen_string_literal: true

module Collavre
  module CreativeHistoryTopic
    extend ActiveSupport::Concern

    included do
      HISTORY_TOPIC_NAME = "History"
      HISTORY_TOPIC_INTERNAL_NAME = "__collavre_history__"
    end

    def history_topic(fallback_user: effective_origin.user)
      target = effective_origin
      target.topics.find_or_create_by!(system_kind: "history") do |topic|
        topic.name = available_history_topic_name(target)
        topic.user = fallback_user
      end
    end

    private

    def available_history_topic_name(target)
      return HISTORY_TOPIC_NAME unless target.topics.exists?(name: HISTORY_TOPIC_NAME)

      candidate = HISTORY_TOPIC_INTERNAL_NAME
      suffix = 1
      while target.topics.exists?(name: candidate)
        suffix += 1
        candidate = "#{HISTORY_TOPIC_INTERNAL_NAME}_#{suffix}"
      end
      candidate
    end
  end
end
