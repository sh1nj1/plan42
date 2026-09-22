# frozen_string_literal: true

module Collavre
  module Workflow
    class HumanHandoff
      def initialize(execution)
        @execution = execution
      end

      def persist!
        safety = Safety.new(@execution)
        owner = safety.owner
        error = safety.reason
        error ||= "permission_revoked" unless owner && owner.id == @execution.owner_id
        return @execution.seal!(error) if error
        inbox = Creative.inbox_for(owner)
        return @execution.seal!("permission_revoked") unless inbox
        persist_notice(owner, inbox)
        @execution.seal!("human_handoff")
      end

      private

      def persist_notice(owner, inbox)
        locale = owner.locale.in?(%w[en ko]) ? owner.locale : "en"
        title = I18n.t("collavre.workflow.runtime.title", locale: locale)
        message = I18n.t("collavre.workflow.runtime.action_needed", locale: locale)
        link = Collavre::Engine.routes.url_helpers.creative_path(@execution.chain.creative_id,
          comment_id: @execution.context.dig("comment", "id"))
        key = "workflow_execution:#{@execution.id}:recipient:#{owner.id}"
        comment = InboxNotice.persist!(inbox: inbox, owner: owner, key: key, content: "[#{message}](#{link})")
        CommentNotificationDelivery.create_or_find_by!(delivery_key: key) do |row|
          row.assign_attributes(inbox_comment_id: comment.id, recipient_id: owner.id, message: message,
            link: link, title: title, workflow_execution_id: @execution.id, push_state: "pending", push_attempts: 0)
        end
      end
    end
  end
end
