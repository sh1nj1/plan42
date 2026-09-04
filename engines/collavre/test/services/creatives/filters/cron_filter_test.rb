# frozen_string_literal: true

require "test_helper"

module Collavre
  module Creatives
    module Filters
      class CronFilterTest < ActiveSupport::TestCase
        setup do
          @tasks = []
          @user = users(:one)
          @with_cron = Creative.create!(user: @user, description: "Scheduled")
          @without_cron = Creative.create!(user: @user, description: "Not scheduled")
          @scope = Creative.where(id: [ @with_cron.id, @without_cron.id ])
          create_task(key: "cron_#{@with_cron.id}_#{SecureRandom.hex(4)}")
        end

        teardown do
          @tasks.each { |task| task.destroy! if task.persisted? }
        end

        test "is active when has_cron is present" do
          assert CronFilter.new(params: { has_cron: "true" }, scope: @scope).active?
          refute CronFilter.new(params: {}, scope: @scope).active?
        end

        test "matches creatives with dynamic cron tasks" do
          result = CronFilter.new(params: { has_cron: "true" }, scope: @scope).match

          assert_equal [ @with_cron.id ], result
        end

        test "matches creatives without dynamic cron tasks when false" do
          result = CronFilter.new(params: { has_cron: "false" }, scope: @scope).match

          assert_equal [ @without_cron.id ], result
        end

        test "ignores static and unrelated dynamic recurring tasks" do
          create_task(key: "cron_#{@without_cron.id}_static", static: true)
          create_task(key: "unrelated_#{@without_cron.id}")

          result = CronFilter.new(params: { has_cron: "true" }, scope: @scope).match

          assert_equal [ @with_cron.id ], result
        end

        private

        def create_task(key:, static: false)
          @tasks << SolidQueue::RecurringTask.create!(
            key: key,
            class_name: "Collavre::CronActionJob",
            schedule: "0 9 * * *",
            static: static,
            arguments: []
          )
        end
      end
    end
  end
end
