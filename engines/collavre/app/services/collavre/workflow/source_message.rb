# frozen_string_literal: true

module Collavre
  module Workflow
    module SourceMessage
      def self.prepend_to(text, context, agent)
        row = DispatchIdentity.admission(context, agent.id)
        return text unless row && row.execution.context["invocation"]
        safety = Safety.new(row.execution)
        return text if safety.reason || !safety.permitted?(agent)
        source = Comment.find_by(id: row.execution.context.dig("comment", "id"))
        return text unless source
        link = Collavre::Engine.routes.url_helpers.creative_path(source.creative_id, comment_id: source.id)
        block = I18n.t("collavre.workflow.runtime.source_message", link: link, content: row.execution.context.dig("comment", "content"))
        "#{block}\n\n#{text}"
      end
    end
  end
end
