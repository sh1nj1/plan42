# frozen_string_literal: true

require "test_helper"

module Collavre
  class Comment
    class ApprovalGateNotificationTest < ActiveSupport::TestCase
      setup do
        @owner = users(:one)
        @agent = users(:two)
        @agent.update!(llm_vendor: "openai")
        @creative = Creative.create!(user: @owner, description: "Release planning")
        @inbox = Creative.inbox_for(@owner)
        @previous_adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test
      end

      teardown do
        ActiveJob::Base.queue_adapter = @previous_adapter
      end

      { "en" => "requested your decision", "ko" => "판단을 요청했습니다" }.each do |locale, phrase|
        test "gate sends a localized decision request to inbox and push in #{locale}" do
          @owner.update!(locale: locale)
          comment = create_request(action: "approval_gate", task_id: 123, tool_call_id: "gate-call")
          delivery = approval_delivery(comment)

          assert_includes delivery.message, phrase
          assert_includes delivery.message, @agent.display_name
          assert_includes delivery.message, "Release planning"
          refute_includes delivery.message, "unknown"
          assert_notification(comment, delivery)
        end
      end

      { "en" => "requested your decision", "ko" => "판단을 요청했습니다" }.each do |locale, phrase|
        test "Claude approval request sends a decision notification in #{locale}" do
          @owner.update!(locale: locale)
          comment = create_request(action: "claude_channel_permission", kind: "approval_request", request_id: "claude-gate")
          delivery = approval_delivery(comment)
          assert_includes delivery.message, phrase
          refute_includes delivery.message, "unknown"
          assert_notification(comment, delivery)
        end
      end

      %w[en ko].each do |locale|
        test "ordinary tool approval keeps its notification in #{locale}" do
          @owner.update!(locale: locale)
          comment = create_request(action: "execute_tool", tool_name: "creative_update")
          delivery = approval_delivery(comment)

          expected = I18n.t("inbox.approval_requested", locale: locale,
                            user: @agent.display_name, tool_name: "creative_update",
                            creative: comment.send(:creative_markdown_link))
          assert_equal expected, delivery.message
          assert_notification(comment, delivery)
        end
      end

      test "Claude approval in an inbox session notifies another human approver" do
        requester = users(:three)
        @creative = Creative.inbox_for(requester)
        topic = @creative.topics.create!(name: "Claude session", user: requester, session_id: "approval-session")
        CreativeShare.create!(creative: @creative, user: @owner, permission: :read)

        comment = nil
        perform_enqueued_jobs(only: CommentNotificationJob) do
          comment = @creative.comments.create!(
            topic: topic, user: @agent, approver: @owner, content: "Publish?",
            action: { action: "claude_channel_permission", kind: "approval_request", request_id: "inbox-gate" }.to_json
          )
        end

        delivery = approval_delivery(comment)
        refute_includes delivery.message, "unknown"
        assert_notification(comment, delivery)
      end

      test "approval notifications in the inbox System topic stay suppressed" do
        comment = @inbox.comments.create!(
          topic: @inbox.system_topic, user: @agent, approver: @owner, content: "Publish?",
          action: { action: "claude_channel_permission", kind: "approval_request", request_id: "system-gate" }.to_json
        )

        refute comment.notification_event["approval_notification"]
        assert_no_difference -> { CommentNotificationDelivery.count } do
          comment.deliver_notifications("created", comment.notification_event.merge("approval_notification" => true))
        end
      end

      private

      def create_request(payload)
        comment = nil
        perform_enqueued_jobs(only: CommentNotificationJob) do
          comment = @creative.comments.create!(
            user: @agent, approver: @owner, content: "Publish the release notes?", action: payload.to_json
          )
        end
        comment
      end

      def approval_delivery(comment)
        CommentNotificationDelivery.find_by!(
          delivery_key: "comment:#{comment.id}:#{comment.notification_revision}:created:approver:recipient:#{@owner.id}"
        )
      end

      def assert_notification(comment, delivery)
        notice = @inbox.comments.find(delivery.inbox_comment_id)
        assert_equal comment.id, notice.quoted_comment_id
        assert_equal delivery.message, notice.content
        assert_enqueued_with(job: PushNotificationJob,
                             args: [ @owner.id, { message: notice.content, link: delivery.link } ])
      end
    end
  end
end
