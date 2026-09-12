# frozen_string_literal: true

require "test_helper"

module Collavre
  class AiAgentDeferredCommitTest < ActiveSupport::TestCase
    # Exercise real commit/rollback hooks, without the fixture transaction.
    self.use_transactional_tests = false

    setup do
      @agent = users(:ai_bot)
      @creative = creatives(:tshirt)
      @topic = @creative.topics.create!(name: "Deferred commit", user: users(:one))
      @waiter = Task.create!(name: "Deferred replay", agent: @agent, creative: @creative,
        topic_id: @topic.id, status: :queued, waiting_notice_scope: Comment::WAITING_NOTICE_TASK)
    end

    teardown do
      @waiter&.destroy!
      @topic&.destroy!
    end

    [ :commit, :rollback, :outside ].each do |outcome|
      test "deferred queue drain follows #{outcome} of the outer admission transaction" do
        drains = []
        drain = lambda do |topic_id, creative_id|
          drains << [ topic_id, creative_id, Task.connection.open_transactions, @waiter.reload.name ]
        end
        park = -> { AiAgentJob.new.send(:park_deferred_waiter, @waiter, @agent, "comment_created", {}, @topic.id, @creative.id) }
        Orchestration::WaitingNoticeManager.stub(:post_topic_concurrency_notice, nil) do
          Orchestration::AgentOrchestrator.stub(:dequeue_next_for_topic, drain) do
            if outcome == :outside
              park.call
            else
              Task.transaction do
                @waiter.update!(name: "Committed replay")
                Task.transaction(requires_new: true) { park.call }
                assert_empty drains, "Promotion must wait for the outermost commit"
                raise ActiveRecord::Rollback if outcome == :rollback
              end
            end
          end
        end
        expected_name = outcome == :commit ? "Committed replay" : "Deferred replay"
        expected = outcome == :rollback ? [] : [ [ @topic.id, @creative.id, 0, expected_name ] ]
        assert_equal expected, drains
        assert_equal expected_name, @waiter.reload.name
      end
    end
  end
end
