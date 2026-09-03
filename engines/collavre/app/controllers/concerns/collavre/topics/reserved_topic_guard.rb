# frozen_string_literal: true

module Collavre
  module Topics
    module ReservedTopicGuard
      extend ActiveSupport::Concern

      included do
        before_action :reject_reserved_topic_name!, only: :create
        before_action :reject_reserved_topic_mutation!,
                      only: %i[update destroy move archive unarchive set_primary_agent]
        before_action :pin_history_topic_last!, only: :reorder
      end

      private

      def reject_reserved_topic_name!
        reject_reserved_topic! if ReservedName.reserved?(@creative, topic_params[:name])
      end

      def reject_reserved_topic_mutation!
        topic = @creative.topics.find(params[:id])
        new_name = topic_params[:name] if action_name == "update"
        reject_reserved_topic! if ReservedName.reserved?(@creative, topic.name) ||
                                  ReservedName.reserved?(@creative, new_name)
      end

      def reject_reserved_topic!
        render json: { error: I18n.t("collavre.topics.reserved_name") }, status: :unprocessable_entity
      end

      def pin_history_topic_last!
        return unless params[:topic_ids].is_a?(Array)

        history_id = @creative.topics.find_by(name: Creative::HISTORY_TOPIC_NAME)&.id
        params[:topic_ids] = [ *(params[:topic_ids].map(&:to_s) - [ history_id&.to_s ]), history_id ].compact
      end
    end
  end
end
