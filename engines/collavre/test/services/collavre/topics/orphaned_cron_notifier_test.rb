# frozen_string_literal: true

require "test_helper"

module Collavre
  module Topics
    class OrphanedCronNotifierTest < ActiveSupport::TestCase
      setup do
        @user = Collavre::User.create!(
          name: "Owner",
          email: "owner-#{SecureRandom.hex(4)}@test.test",
          password: "password123"
        )
        @creative = Collavre::Creative.create!(
          description: "Cron Host",
          user: @user
        )
        # A non-Main topic that will be "deleted"
        @topic = @creative.topics.create!(name: "Counseling", user: @user)
      end

      def create_cron(creative_id:, topic_id:, message: "@Ming: do the thing")
        SolidQueue::RecurringTask.create!(
          key: "cron_#{creative_id}_#{SecureRandom.hex(4)}",
          class_name: "Collavre::CronActionJob",
          schedule: "0 10 * * *",
          queue_name: "default",
          static: false,
          description: "Cron job for creative #{creative_id}",
          arguments: [ {
            creative_id: creative_id,
            topic_id: topic_id,
            agent_id: @user.id,
            message: message
          } ]
        )
      end

      test "posts a system comment to the creative's main topic when a cron targets the deleted topic" do
        cron = create_cron(creative_id: @creative.id, topic_id: @topic.id)
        deleted_name = @topic.name
        deleted_id = @topic.id
        @topic.destroy!

        assert_difference -> { @creative.reload.comments.where(user_id: nil).count }, 1 do
          OrphanedCronNotifier.new(topic_id: deleted_id, topic_name: deleted_name).call
        end

        notice = @creative.comments.where(user_id: nil).order(:created_at).last
        assert_equal @creative.main_topic.id, notice.topic_id
        assert_includes notice.content, cron.key
        assert_includes notice.content, "Counseling"
      end

      test "leaves the recurring task in place (notify only)" do
        cron = create_cron(creative_id: @creative.id, topic_id: @topic.id)
        deleted_id = @topic.id
        @topic.destroy!

        OrphanedCronNotifier.new(topic_id: deleted_id, topic_name: "Counseling").call

        assert SolidQueue::RecurringTask.exists?(key: cron.key), "cron must NOT be cancelled"
      end

      test "does nothing for crons targeting a different topic" do
        other = @creative.topics.create!(name: "Other", user: @user)
        create_cron(creative_id: @creative.id, topic_id: other.id)
        deleted_id = @topic.id
        @topic.destroy!

        assert_no_difference -> { Collavre::Comment.where(user_id: nil).count } do
          OrphanedCronNotifier.new(topic_id: deleted_id, topic_name: "Counseling").call
        end
      end

      test "ignores crons whose topic_id is nil (main-topic crons)" do
        create_cron(creative_id: @creative.id, topic_id: nil)
        deleted_id = @topic.id
        @topic.destroy!

        assert_no_difference -> { Collavre::Comment.where(user_id: nil).count } do
          OrphanedCronNotifier.new(topic_id: deleted_id, topic_name: "Counseling").call
        end
      end
    end
  end
end
