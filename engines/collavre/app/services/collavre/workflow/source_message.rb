# frozen_string_literal: true

module Collavre
  module Workflow
    module SourceMessage
      def self.prepend_to(text, context, agent)
        execution, source = authorized_source(context, agent)
        return text unless source
        link = Collavre::Engine.routes.url_helpers.creative_path(source.creative_id, comment_id: source.id)
        block = I18n.t("collavre.workflow.runtime.source_message", link: link, content: execution.context.dig("comment", "content"))
        "#{block}\n\n#{text}"
      end

      def self.content(context, agent)
        execution, source = authorized_source(context, agent)
        execution.context.dig("comment", "content") if source
      end

      def self.comment_id(context, agent)
        _, source = authorized_source(context, agent)
        source&.id
      end

      def self.images(context, agent)
        _, source = authorized_source(context, agent)
        source ? source.images.map(&:blob) : []
      end

      def self.authorized_source(context, agent)
        row = DispatchIdentity.admission(context, agent.id)
        return unless row && row.execution.context["invocation"]
        safety = Safety.new(row.execution)
        return if safety.reason || !safety.permitted?(agent)
        [ row.execution, Comment.find_by(id: row.execution.context.dig("comment", "id")) ]
      end
      private_class_method :authorized_source
    end
  end
end
