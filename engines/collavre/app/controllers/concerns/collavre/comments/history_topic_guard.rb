# frozen_string_literal: true

module Collavre
  module Comments
    module HistoryTopicGuard
      extend ActiveSupport::Concern

      included do
        before_action :reject_history_topic_comment!, only: :create
      end

      private

      def reject_history_topic_comment!
        topic_id = params.dig(:comment, :topic_id).presence
        return unless topic_id && @creative.topics.where(id: topic_id, name: Creative::HISTORY_TOPIC_NAME).exists?

        render json: { error: I18n.t("collavre.creative_history.read_only") }, status: :forbidden
      end
    end
  end
end
