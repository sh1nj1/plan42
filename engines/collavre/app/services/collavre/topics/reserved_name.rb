module Collavre
  module Topics
    module ReservedName
      module_function

      def reserved?(creative, name)
        name == Creative::MAIN_TOPIC_NAME ||
          (creative.inbox? && name == Creative::SYSTEM_TOPIC_NAME)
      end

      def reject!(creative, name, error_class: ArgumentError)
        return unless reserved?(creative, name)

        raise error_class, I18n.t("collavre.topics.reserved_name")
      end
    end
  end
end
