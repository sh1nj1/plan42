# frozen_string_literal: true

module Collavre
  module Creatives
    # Records a visible warning when an enabled trigger has no writable agent.
    class DropTriggerMissingAgentNotifier
      def initialize(creative:)
        @creative = creative
      end

      def call
        return if creative.find_ai_agent(:write)

        topic = creative.topics.find_or_create_by!(name: "Drop Trigger") do |record|
          record.user = creative.user
        end

        creative.comments.create!(
          content: I18n.t("collavre.drop_trigger.no_agent", parent_description: creative.creative_snippet),
          topic_id: topic.id,
          private: false,
          skip_default_user: true
        )
      end

      private

      attr_reader :creative
    end
  end
end
