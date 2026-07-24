# frozen_string_literal: true

require "test_helper"

module Collavre
  class CommentDispatchTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      @creative = creatives(:tshirt)
      Current.session = OpenStruct.new(user: @user)
    end

    teardown do
      Current.reset
    end

    test "dispatches to orchestration after create" do
      dispatched_event = nil
      dispatched_context = nil

      SystemEvents::Dispatcher.stub(:dispatch, ->(event, context) {
        dispatched_event = event
        dispatched_context = context
        []
      }) do
        @creative.comments.create!(content: "test dispatch", user: @user)
      end

      assert_equal "comment_created", dispatched_event
      assert_equal "test dispatch", dispatched_context.dig(:comment, :content)
      assert_equal @creative.id, dispatched_context.dig(:creative, :id)
    end

    test "does not dispatch for private comments" do
      dispatched = false
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { dispatched = true; [] }) do
        @creative.comments.create!(content: "private msg", user: @user, private: true)
      end

      refute dispatched, "Private comments should not dispatch"
    end

    test "does not dispatch for system notices (skip_default_user)" do
      dispatched = false
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { dispatched = true; [] }) do
        @creative.comments.create!(content: "system notice", skip_default_user: true)
      end

      refute dispatched, "System notices should not dispatch"
    end

    test "does not dispatch when skip_dispatch is set" do
      dispatched = false
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { dispatched = true; [] }) do
        @creative.comments.create!(content: "command response", user: @user, skip_dispatch: true)
      end

      refute dispatched, "Comments with skip_dispatch should not dispatch"
    end

    test "does not dispatch for AI user comments" do
      ai_bot = users(:ai_bot)
      dispatched = false
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { dispatched = true; [] }) do
        @creative.comments.create!(content: "AI reply", user: ai_bot)
      end

      refute dispatched, "AI user comments should not dispatch (A2A has its own path)"
    end

    test "does not dispatch for nil user comments" do
      dispatched = false
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { dispatched = true; [] }) do
        @creative.comments.create!(content: "system msg", skip_default_user: true)
      end

      refute dispatched, "Nil user comments should not dispatch"
    end

    test "dispatch failure is re-raised for job retry" do
      assert_raises(RuntimeError, "dispatch error") do
        SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { raise "dispatch error" }) do
          @creative.comments.create!(content: "triggers error", user: @user)
        end
      end
    end
  end
end
