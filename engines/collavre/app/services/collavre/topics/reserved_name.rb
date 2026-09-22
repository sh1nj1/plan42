module Collavre
  module Topics
    module ReservedName
      module_function

      def reserved?(creative, name)
        name == Creative::MAIN_TOPIC_NAME ||
          name == Creative::HISTORY_TOPIC_NAME ||
          (creative.inbox? && name == Creative::SYSTEM_TOPIC_NAME)
      end

      def reject!(creative, name, error_class: ArgumentError)
        return unless reserved?(creative, name)

        raise error_class, I18n.t("collavre.topics.reserved_name")
      end

      def reserved_topic?(creative, topic)
        topic.history? || topic.name == Creative::MAIN_TOPIC_NAME ||
          (creative.inbox? && topic.name == Creative::SYSTEM_TOPIC_NAME)
      end
    end
  end
end
