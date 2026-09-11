# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    # The "⏳" notice has two doors — AgentOrchestrator#enqueue_jobs and
    # AiAgentJob's late slot check — and one owner. These are the invariants
    # that owner exists to hold: one answer about what a notice speaks for, one
    # guard per scope, and a notice only while the wait it describes is real.
    class WaitingNoticeManagerTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @agent = users(:ai_bot)
        @creative = creatives(:tshirt)
        @topic = Topic.create!(name: "Notice owner", creative: @creative, user: @user)
      end

      def notices
        Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil)
               .select { |c| c.content.start_with?(Comment::WAITING_NOTICE_PREFIX) }
      end

      def waiter!(scope, status: "queued")
        Task.create!(
          name: "Waiter", status: status, trigger_event_name: "comment_created",
          agent: @agent, topic_id: @topic.id, creative_id: @creative.id,
          waiting_notice_scope: scope
        )
      end

      def never = ->(*) { flunk("the policy fallback must not be consulted") }

      # The waiter recorded its scope under the admission lock when it was
      # parked. Resolving the policy again here is how the notice, the fold and
      # the stop button come to disagree about a wait whose policy changed
      # mid-flight — so a waiter is the only thing asked when one exists.
      test "the policy fallback is not consulted when a waiter carries the scope" do
        waiter = waiter!(Comment::WAITING_NOTICE_TASK)

        WaitingNoticeManager.post(@creative.id, @topic.id, :topic_concurrency,
                                  deferred: true, waiter: waiter,
                                  shared_without_waiter: never)

        assert_equal [ waiter.id ], notices.map(&:waiting_notice_task_id),
                     "a TASK-scoped waiter gets the per-deferral notice its row asked for"
      end

      # A shared notice speaks for the topic, so it carries no task id and the
      # second deferral in a burst adds nothing beside it.
      test "a topic-scoped waiter gets one shared notice for the whole burst" do
        first = waiter!(Comment::WAITING_NOTICE_TOPIC)
        second = waiter!(Comment::WAITING_NOTICE_TOPIC)

        [ first, second ].each do |waiter|
          WaitingNoticeManager.post(@creative.id, @topic.id, :topic_concurrency,
                                    deferred: true, waiter: waiter,
                                    shared_without_waiter: never)
        end

        assert_equal 1, notices.size, "one waiting notice per topic, not one per deferral"
        assert_equal [ Comment::WAITING_NOTICE_TOPIC ], notices.map(&:waiting_notice_scope)
        assert_nil notices.sole.waiting_notice_task_id
      end

      # The waiter commits before its notice goes up, so the blocker can finish
      # and promote it in between. A notice posted after that describes a wait
      # that is already over, and nothing would ever take it back down.
      test "no notice goes up for a waiter that left the queue first" do
        promoted = waiter!(Comment::WAITING_NOTICE_TASK, status: "pending")

        WaitingNoticeManager.post(@creative.id, @topic.id, :topic_concurrency,
                                  deferred: true, waiter: promoted,
                                  shared_without_waiter: never)

        assert_empty notices, "a stop button for a turn that is already running"
      end

      # :delayed is not a deferral. The dispatch is still going to run, so there
      # is no waiter for the notice to speak for — and the queued-waiter guard
      # must not be what decides whether it appears.
      test "a delayed notice is posted with no waiter and no guard" do
        WaitingNoticeManager.post(@creative.id, @topic.id, :busy,
                                  deferred: false, waiter: nil,
                                  shared_without_waiter: never)

        notice = notices.sole
        assert_not notice.topic_concurrency_defer, "only :deferred parks a topic waiter"
        assert_nil notice.waiting_notice_scope, "a :delayed notice speaks for nobody"
      end

      # Without a waiter the policy is the only thing left to ask, and its
      # answer picks the scope.
      test "the policy fallback decides the scope for a waiterless deferral" do
        waiter!(Comment::WAITING_NOTICE_TOPIC)

        WaitingNoticeManager.post(@creative.id, @topic.id, :topic_concurrency,
                                  deferred: true, waiter: nil,
                                  shared_without_waiter: -> { true })

        assert_equal [ Comment::WAITING_NOTICE_TOPIC ], notices.map(&:waiting_notice_scope)
      end

      # Name the agent holding the slot so a waiting user can reach its stop
      # button rather than an anonymous "another task is running" dead end.
      test "the reason text names the agent holding the topic slot" do
        Task.create!(name: "Running", status: "running", trigger_event_name: "e",
                     agent: @agent, topic_id: @topic.id, creative_id: @creative.id)

        text = WaitingNoticeManager.waiting_reason_text(:topic_concurrency, @topic.id, @creative.id)

        assert_includes text, @agent.name
      end
    end
  end
end
