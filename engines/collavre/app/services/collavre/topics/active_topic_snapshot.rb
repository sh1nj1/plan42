module Collavre
  module Topics
    class ActiveTopicSnapshot
      attr_reader :topics, :main_topic, :system_topic

      def initialize(creative:, user:)
        @creative = creative
        @user = user
        # Derive reserved IDs from the same materialized list we render. A
        # deletion between a separate reserved lookup and this query otherwise
        # leaves a deleted ID in the response with no matching sidebar entry.
        @topics = creative.topics.active.includes(primary_agent: { avatar_attachment: :blob }).order(:created_at).to_a
        @main_topic = ensure_topic(Creative::MAIN_TOPIC_NAME, :main_topic)
        @system_topic = ensure_topic(Creative::SYSTEM_TOPIC_NAME, :system_topic) if creative.inbox?
        @topics = topics.partition { |topic| !topic.history? }.flatten
      end

      private

      def ensure_topic(name, method)
        topics.find { |topic| topic.name == name } || @creative.public_send(method, fallback_user: @user).tap do |topic|
          topics << topic unless topic.archived_at?
        end
      end
    end
  end
end
