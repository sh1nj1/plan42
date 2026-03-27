# frozen_string_literal: true

require "test_helper"

module Collavre
  class CreativeDropTriggerTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @owner = users(:one)
      @ai_bot = users(:ai_bot)
      Current.session = OpenStruct.new(user: @owner)
      @original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test

      @trigger_parent = Creative.create!(
        user: @owner,
        description: "Trigger Parent",
        data: { "trigger" => { "on_child_enter" => true } }
      )
      @normal_parent = Creative.create!(user: @owner, description: "Normal Parent")
      CreativeShare.create!(creative: @trigger_parent, user: @ai_bot, permission: :feedback)
    end

    teardown do
      ActiveJob::Base.queue_adapter = @original_adapter
      Current.reset
    end

    test "drop_trigger_enabled? returns true when configured" do
      assert @trigger_parent.drop_trigger_enabled?
    end

    test "drop_trigger_enabled? returns false when not configured" do
      refute @normal_parent.drop_trigger_enabled?
    end

    test "drop_trigger_enabled? returns false for nil data" do
      creative = Creative.new(data: nil)
      refute creative.drop_trigger_enabled?
    end

    test "creating child under trigger parent enqueues DropTriggerJob" do
      assert_enqueued_with(job: DropTriggerJob) do
        Creative.create!(user: @owner, parent: @trigger_parent, description: "New Child")
      end
    end

    test "creating child under normal parent does not enqueue DropTriggerJob" do
      assert_no_enqueued_jobs(only: DropTriggerJob) do
        Creative.create!(user: @owner, parent: @normal_parent, description: "New Child")
      end
    end

    test "moving creative into trigger parent enqueues DropTriggerJob" do
      child = Creative.create!(user: @owner, description: "Orphan")
      clear_enqueued_jobs

      assert_enqueued_with(job: DropTriggerJob) do
        child.update!(parent: @trigger_parent)
      end
    end

    test "moving creative into normal parent does not enqueue DropTriggerJob" do
      child = Creative.create!(user: @owner, description: "Orphan")
      clear_enqueued_jobs

      assert_no_enqueued_jobs(only: DropTriggerJob) do
        child.update!(parent: @normal_parent)
      end
    end

    test "creating child enqueues exactly one DropTriggerJob not two" do
      assert_enqueued_jobs(1, only: DropTriggerJob) do
        Creative.create!(user: @owner, parent: @trigger_parent, description: "Single Trigger Child")
      end
    end
  end
end
