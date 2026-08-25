module Collavre
  module Topics
    class LastTopicPreferencePayload
      def initialize(creative:, user:)
        @creative = creative
        @user = user
      end

      def call
        preference = UserCreativePreference.find_by(user_id: @user&.id, creative_id: @creative.id)
        {
          last_topic_id: preference&.last_topic_id,
          last_topic_revision: preference && [ preference.id, preference.last_topic_revision ]
        }
      end
    end
  end
end
