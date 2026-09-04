# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class CronCreateServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)
        @main_topic = @creative.main_topic(fallback_user: @user)
        @topic = Collavre::Topic.create!(
          name: "Cron Test Topic",
          creative: @creative,
          user: @user
        )
        Current.user = @user
      end

      teardown do
        SolidQueue::RecurringTask.where(static: false).destroy_all
        @topic&.destroy
        Current.user = nil
      end

      test "creates a recurring task with topic_name" do
        result = CronCreateService.new.call(
          creative_id: @creative.id,
          topic_name: "Cron Test Topic",
          schedule: "0 9 * * *",
          message: "Daily check-in",
          description: "Morning check"
        )

        assert result[:success]
        assert result[:key].start_with?("cron_#{@creative.id}_")
        assert_equal "Cron Test Topic", result[:topic_name]

        task = SolidQueue::RecurringTask.find_by(key: result[:key])
        assert_not_nil task
        assert_equal false, task.static
        assert_equal "Collavre::CronActionJob", task.class_name
        assert_equal "0 9 * * *", task.schedule
        assert_equal "Morning check", task.description

        args = task.arguments.first
        assert_equal @topic.id, args[:topic_id]
      end

      test "topic_name Main resolves to Main topic_id" do
        result = CronCreateService.new.call(
          creative_id: @creative.id,
          topic_name: "Main",
          schedule: "0 9 * * *",
          message: "Main topic message"
        )

        assert result[:success]

        task = SolidQueue::RecurringTask.find_by(key: result[:key])
        args = task.arguments.first
        assert_equal @main_topic.id, args[:topic_id]
      end

      test "topic_name main (lowercase) resolves to Main topic" do
        result = CronCreateService.new.call(
          creative_id: @creative.id,
          topic_name: "main",
          schedule: "0 9 * * *",
          message: "Main topic message"
        )

        assert result[:success]
        task = SolidQueue::RecurringTask.find_by(key: result[:key])
        args = task.arguments.first
        assert_equal @main_topic.id, args[:topic_id]
      end

      test "stores arguments for CronActionJob" do
        result = CronCreateService.new.call(
          creative_id: @creative.id,
          topic_name: "Cron Test Topic",
          schedule: "0 9 * * *",
          message: "Test message"
        )

        task = SolidQueue::RecurringTask.find_by(key: result[:key])
        args = task.arguments.first
        assert_equal @creative.id, args[:creative_id]
        assert_equal @topic.id, args[:topic_id]
        assert_equal @user.id, args[:agent_id]
        assert_equal "Test message", args[:message]
      end

      test "rejects invalid cron schedule" do
        result = CronCreateService.new.call(
          creative_id: @creative.id,
          topic_name: "Cron Test Topic",
          schedule: "not a valid schedule",
          message: "test"
        )

        assert result[:error]
        assert_match(/Invalid cron schedule/, result[:error])
      end

      test "rejects when creative not found" do
        result = CronCreateService.new.call(
          creative_id: 999_999,
          topic_name: "Main",
          schedule: "0 9 * * *",
          message: "test"
        )

        assert_equal "Creative not found", result[:error]
      end

      test "creates a missing topic and targets it" do
        broadcast = nil

        TopicsChannel.stub(:broadcast_to, ->(*args) { broadcast = args }) do
          result = CronCreateService.new.call(
            creative_id: @creative.id,
            topic_name: "New Cron Topic",
            schedule: "0 9 * * *",
            message: "test"
          )

          assert result[:success]
          task = SolidQueue::RecurringTask.find_by!(key: result[:key])
          topic = @creative.topics.find_by!(name: "New Cron Topic")
          assert_equal @user, topic.user
          assert_equal topic.id, task.arguments.first[:topic_id]
          assert_equal [ @creative, { action: "created", topic: topic.slice(:id, :name), user_id: @user.id } ], broadcast
        end
      end

      test "does not create a missing topic for an invalid schedule" do
        assert_no_difference -> { @creative.topics.count } do
          result = CronCreateService.new.call(
            creative_id: @creative.id,
            topic_name: "Invalid Schedule Topic",
            schedule: "not a valid schedule",
            message: "test"
          )

          assert_match(/Invalid cron schedule/, result[:error])
        end
      end

      test "keeps the cron successful when broadcasting a created topic fails" do
        warning = nil
        result = Rails.logger.stub(:warn, ->(message) { warning = message }) do
          TopicsChannel.stub(:broadcast_to, ->(*) { raise "cable unavailable" }) do
            CronCreateService.new.call(
              creative_id: @creative.id,
              topic_name: "Broadcast Failure Topic",
              schedule: "0 9 * * *",
              message: "test"
            )
          end
        end

        assert result[:success]
        topic = @creative.topics.find_by!(name: "Broadcast Failure Topic")
        task = SolidQueue::RecurringTask.find_by!(key: result[:key])
        assert_equal topic.id, task.arguments.first[:topic_id]
        assert_match(/Failed to broadcast created topic #{topic.id}: cable unavailable/, warning)
      end

      test "removes a newly created topic when recurring task creation fails" do
        error = SolidQueue::RecurringTask.stub(:create!, ->(**) { raise "queue unavailable" }) do
          assert_raises(RuntimeError) do
            CronCreateService.new.call(
              creative_id: @creative.id,
              topic_name: "Task Failure Topic",
              schedule: "0 9 * * *",
              message: "test"
            )
          end
        end

        assert_equal "queue unavailable", error.message
        assert_nil @creative.topics.find_by(name: "Task Failure Topic")
      end

      test "keeps an existing topic when recurring task creation fails" do
        error = SolidQueue::RecurringTask.stub(:create!, ->(**) { raise "queue unavailable" }) do
          assert_raises(RuntimeError) do
            CronCreateService.new.call(
              creative_id: @creative.id,
              topic_name: @topic.name,
              schedule: "0 9 * * *",
              message: "test"
            )
          end
        end

        assert_equal "queue unavailable", error.message
        assert @topic.reload
      end

      test "keeps a newly created topic adopted by a concurrent recurring task" do
        original_create = SolidQueue::RecurringTask.method(:create!)
        adopted_task = nil
        failing_create = lambda do |**attributes|
          adopted_task = original_create.call(**attributes.merge(key: "#{attributes[:key]}_adopted"))
          raise "queue unavailable"
        end

        error = SolidQueue::RecurringTask.stub(:create!, failing_create) do
          assert_raises(RuntimeError) do
            CronCreateService.new.call(
              creative_id: @creative.id,
              topic_name: "Adopted Topic",
              schedule: "0 9 * * *",
              message: "test"
            )
          end
        end

        topic = @creative.topics.find_by!(name: "Adopted Topic")
        assert_equal "queue unavailable", error.message
        assert_equal topic.id, adopted_task.arguments.first[:topic_id]
      end

      test "removes a new topic and preserves the original error when the adoption check fails" do
        checker = Object.new
        checker.define_singleton_method(:any?) { raise "queue still unavailable" }
        warning = nil

        error = Rails.logger.stub(:warn, ->(message) { warning = message }) do
          Crons::RecurringTopicTasks.stub(:new, checker) do
            SolidQueue::RecurringTask.stub(:create!, ->(**) { raise "queue unavailable" }) do
              assert_raises(RuntimeError) do
                CronCreateService.new.call(
                  creative_id: @creative.id,
                  topic_name: "Unavailable Queue Topic",
                  schedule: "0 9 * * *",
                  message: "test"
                )
              end
            end
          end
        end

        assert_equal "queue unavailable", error.message
        assert_nil @creative.topics.find_by(name: "Unavailable Queue Topic")
        assert_match(/Failed to check topic .* adoption: queue still unavailable/, warning)
      end

      test "rejects a missing reserved topic name" do
        result = CronCreateService.new.call(
          creative_id: @creative.id,
          topic_name: Creative::HISTORY_TOPIC_NAME,
          schedule: "0 9 * * *",
          message: "test"
        )

        assert_equal I18n.t("collavre.topics.reserved_name"), result[:error]
        assert_nil @creative.topics.find_by(name: Creative::HISTORY_TOPIC_NAME)
      end

      test "rejects the read-only History topic" do
        history = @creative.history_topic

        result = CronCreateService.new.call(
          creative_id: @creative.id,
          topic_name: history.name,
          schedule: "0 9 * * *",
          message: "Hidden history message"
        )

        assert_equal I18n.t("collavre.creative_history.read_only"), result[:error]
        assert_empty SolidQueue::RecurringTask.where(static: false)
      end

      test "rechecks History status while creating the recurring task" do
        history = @creative.history_topic
        service = CronCreateService.new

        result = service.stub(:resolve_topic, history) do
          service.call(
            creative_id: @creative.id,
            topic_name: history.name,
            schedule: "0 9 * * *",
            message: "Racing history message"
          )
        end

        assert_equal I18n.t("collavre.creative_history.read_only"), result[:error]
        assert_empty SolidQueue::RecurringTask.where(static: false)
      end

      test "generates unique keys" do
        result1 = CronCreateService.new.call(
          creative_id: @creative.id,
          topic_name: "Cron Test Topic",
          schedule: "0 9 * * *",
          message: "test 1"
        )
        result2 = CronCreateService.new.call(
          creative_id: @creative.id,
          topic_name: "Cron Test Topic",
          schedule: "0 10 * * *",
          message: "test 2"
        )

        assert_not_equal result1[:key], result2[:key]
      end

      test "rejects a topic that moved after resolution and before creation" do
        destination = Creative.create!(description: "Cron destination", user: @user)
        service = CronCreateService.new
        Collavre::Topics::TopicMove.new(topic: @topic, target_creative: destination).call

        result = service.stub(:resolve_topic, @topic) do
          service.call(
            creative_id: @creative.id,
            topic_name: @topic.name,
            schedule: "0 9 * * *",
            message: "Stale cron"
          )
        end

        assert_equal I18n.t("collavre.comments.invalid_topic"), result[:error]
        assert_empty SolidQueue::RecurringTask.where(static: false)
      end
    end
  end
end
