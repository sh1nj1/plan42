# frozen_string_literal: true

module Collavre
  module Quota
    class Notice
      def self.exhausted!(task)
        return unless task.creative_id

        Comment.create!(creative_id: task.creative_id, topic_id: task.topic_id,
                        user: nil, skip_default_user: true, skip_dispatch: true,
                        content: I18n.t("collavre.quota.exhausted", locale: task.agent.locale.presence || :en))
      end
    end
  end
end
