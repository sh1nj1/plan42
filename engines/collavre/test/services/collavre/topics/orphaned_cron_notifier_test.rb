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

      def create_cron(creative_id:, topic_id:, message: "@Ming: do the thing", description: nil)
        SolidQueue::RecurringTask.create!(
          key: "cron_#{creative_id}_#{SecureRandom.hex(4)}",
          class_name: "Collavre::CronActionJob",
          schedule: "0 10 * * *",
          queue_name: "default",
          static: false,
          description: description || "Cron job for creative #{creative_id}",
          arguments: [ {
            creative_id: creative_id,
            topic_id: topic_id,
            agent_id: @user.id,
            message: message
          } ]
        )
      end

      test "deletes a matching cron and posts a recreation command to the creative's main topic" do
        message = "Ask \"Ming\" to do the thing\nand follow up"
        cron = create_cron(
          creative_id: @creative.id,
          topic_id: @topic.id,
          message: message,
          description: "Daily follow-up"
        )
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
        assert_not SolidQueue::RecurringTask.exists?(key: cron.key)

        command = notice.content.lines.find { |line| line.start_with?("/cron_create ") }
        assert_not_nil command
        payload = JSON.parse(command.delete_prefix("/cron_create "))
        assert_equal(
          {
            "creative_id" => @creative.id,
            "topic_name" => "Counseling",
            "schedule" => "0 10 * * *",
            "message" => message,
            "description" => "Daily follow-up"
          },
          payload
        )
      end

      test "does nothing for crons targeting a different topic" do
        other = @creative.topics.create!(name: "Other", user: @user)
        cron = create_cron(creative_id: @creative.id, topic_id: other.id)
        deleted_id = @topic.id
        @topic.destroy!

        assert_no_difference -> { Collavre::Comment.where(user_id: nil).count } do
          OrphanedCronNotifier.new(topic_id: deleted_id, topic_name: "Counseling").call
        end
        assert SolidQueue::RecurringTask.exists?(key: cron.key)
      end

      test "deletes every matching cron before posting notices" do
        crons = 2.times.map { create_cron(creative_id: @creative.id, topic_id: @topic.id) }
        deleted_id = @topic.id
        @topic.destroy!

        Collavre::Comment.stub(:create!, ->(*) { raise "notice failed" }) do
          assert_raises(RuntimeError) do
            OrphanedCronNotifier.new(topic_id: deleted_id, topic_name: "Counseling").call
          end
        end

        assert_empty SolidQueue::RecurringTask.where(key: crons.map(&:key))
      end

      test "keeps the notice as a system message even when a deleter is Current.user" do
        create_cron(creative_id: @creative.id, topic_id: @topic.id)
        deleted_id = @topic.id
        @topic.destroy!

        # Simulate the controller path where the admin deleting the topic is the
        # current user; the notice must still be a system message (user nil) so
        # it does not get attributed to them or trigger AI orchestration.
        Collavre::Current.user = @user
        begin
          OrphanedCronNotifier.new(topic_id: deleted_id, topic_name: "Counseling").call
        ensure
          Collavre::Current.user = nil
        end

        notice = @creative.comments.order(:created_at).last
        assert_nil notice.user_id, "notice must remain a system message (user nil)"
      end

      test "posts to the origin's main topic when the cron creative is a linked/child creative" do
        # CronCreateService resolves the target topic on the origin but stores the
        # original (linked) creative id. The notice must land on the origin's Main
        # topic, consistent with Comment#use_origin_creative rewriting to origin.
        other_user = Collavre::User.create!(
          name: "Sharee",
          email: "sharee-#{SecureRandom.hex(4)}@test.test",
          password: "password123"
        )
        linked = Collavre::Creative.create!(origin_id: @creative.id, user: other_user)

        cron = create_cron(creative_id: linked.id, topic_id: @topic.id)
        deleted_id = @topic.id
        @topic.destroy!

        OrphanedCronNotifier.new(topic_id: deleted_id, topic_name: "Counseling").call

        notice = @creative.reload.comments.where(user_id: nil).order(:created_at).last
        assert_not_nil notice, "notice must be posted on the origin creative"
        assert_equal @creative.main_topic.id, notice.topic_id
        # Topic and (origin-rewritten) creative must be consistent — no orphaned topic.
        assert_equal notice.creative_id, notice.topic.creative_id
        assert_not SolidQueue::RecurringTask.exists?(key: cron.key)

        command = notice.content.lines.find { |line| line.start_with?("/cron_create ") }
        payload = JSON.parse(command.delete_prefix("/cron_create "))
        assert_equal linked.id, payload.fetch("creative_id")
      end

      test "ignores crons whose topic_id is nil (main-topic crons)" do
        cron = create_cron(creative_id: @creative.id, topic_id: nil)
        deleted_id = @topic.id
        @topic.destroy!

        assert_no_difference -> { Collavre::Comment.where(user_id: nil).count } do
          OrphanedCronNotifier.new(topic_id: deleted_id, topic_name: "Counseling").call
        end
        assert SolidQueue::RecurringTask.exists?(key: cron.key)
      end
    end
  end
end
