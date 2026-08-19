# frozen_string_literal: true

module Collavre
  module Tools
    # Turns the `topic_ids` parameter of the read tools into topics, and reports
    # the ones it could not turn into topics instead of raising.
    #
    # A caller asking about three topics has usually copied the ids out of a
    # conversation, so one of them being stale or unshared is ordinary. Failing
    # the whole call there would throw away the two that worked and give no way
    # to tell which id was the bad one.
    module TopicSelection
      # A ceiling on topics per call, not on messages — that is max_chars' job.
      # This one exists because each topic costs a header, a totals query and a
      # window query, and a caller that pastes forty ids has stopped planning
      # and started dumping.
      MAX_TOPICS = 20

      module_function

      # Returns [topics, errors], preserving the caller's id order so a numbered
      # request reads back in the order it was asked.
      def resolve(ids, user: Collavre::Current.user)
        by_id = Topic.where(id: ids).index_by(&:id)

        ids.each_with_object([ [], [] ]) do |id, (topics, errors)|
          error = rejection_for(by_id[id], user)
          error ? errors << { topic_id: id, error: error } : topics << by_id[id]
        end
      end

      # Deliberately the same message for missing and unreadable. Distinguishing
      # them would let a caller probe which topic ids exist on creatives they
      # cannot see.
      def rejection_for(topic, user)
        return "Topic not found or not readable" if topic.nil?
        return nil if TopicAuthorizer.readable?(topic, user: user)

        "Topic not found or not readable"
      end
    end
  end
end
