# frozen_string_literal: true

module Collavre
  module Comments
    module TopicMutation
      module_function

      def call(topic_id, creative_id)
        applied = false
        ActiveRecord::Base.transaction do
          next unless Orchestration::TopicSlot.lock_matches_context?(topic_id, creative_id)

          yield
          applied = true
        end
        applied
      end
    end
  end
end
