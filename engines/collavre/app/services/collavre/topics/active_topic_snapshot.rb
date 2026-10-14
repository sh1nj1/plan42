module Collavre
  module Topics
    class ActiveTopicSnapshot
      attr_reader :topics, :main_topic, :system_topic

      def initialize(creative:, user:)
        @creative = creative
        @user = user
        # Materialize ordinary topics once; revalidate reserved rows afterward
        # because deletion may commit while this list is being loaded.
        @topics = creative.topics.active.includes(primary_agent: { avatar_attachment: :blob }).order(:created_at).to_a
        @main_topic = ensure_topic(Creative::MAIN_TOPIC_NAME, :main_topic)
        @system_topic = ensure_topic(Creative::SYSTEM_TOPIC_NAME, :system_topic) if creative.inbox?
        @topics = topics.partition { |topic| !topic.history? }.flatten
      end

      private

      def ensure_topic(name, method)
        @creative.public_send(method, fallback_user: @user).tap do |topic|
          index = topics.index { |row| row.name == name }
          return topics[index] if index && topics[index].id == topic.id

          topics.delete_at(index) if index
          topics << topic unless topic.archived_at?
        end
      end
    end
  end
end
