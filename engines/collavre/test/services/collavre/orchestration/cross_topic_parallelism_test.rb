# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    class CrossTopicParallelismTest < ActiveSupport::TestCase
      setup do
        @creative = creatives(:tshirt)
        @user = users(:one)
        @agent = users(:ai_bot)
        @agent.update!(searchable: true)

        @topic_a = Topic.create!(name: "Topic A", creative: @creative, user: @user)
        @topic_b = Topic.create!(name: "Topic B", creative: @creative, user: @user)

        ResourceTracker.for(@agent).reset!
      end

      teardown do
        ResourceTracker.for(@agent).reset!
      end

      test "same agent can run in parallel across different topics" do
        # Simulate: agent already running in Topic A
        Task.create!(
          name: "Running in Topic A",
          status: "running",
          trigger_event_name: "comment_created",
          agent: @agent,
          topic_id: @topic_a.id
        )
        ResourceTracker.for(@agent).reserve!("job-topic-a")

        # Now schedule same agent in Topic B
        context_b = {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => @topic_b.id }
        }

        scheduler = Scheduler.new(context_b)
        decisions = scheduler.schedule([@agent])

        assert_equal 1, decisions.size
        assert_equal :immediate, decisions.first[:timing],
          "Same agent should be allowed to run in a different topic, " \
          "but got: #{decisions.first[:timing]} (reason: #{decisions.first[:reason]})"
      end

      test "same agent is deferred in same topic when already running" do
        Task.create!(
          name: "Running in Topic A",
          status: "running",
          trigger_event_name: "comment_created",
          agent: @agent,
          topic_id: @topic_a.id
        )
        ResourceTracker.for(@agent).reserve!("job-topic-a")

        # Schedule same agent in SAME Topic A
        context_a = {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => @topic_a.id }
        }

        scheduler = Scheduler.new(context_a)
        decisions = scheduler.schedule([@agent])

        assert_equal :deferred, decisions.first[:timing],
          "Same agent should be deferred in same topic"
      end

      test "same agent running in topic A does not block topic B via Main" do
        # Key question: does a comment in Topic A also create a Main topic event?
        # If so, does Main's running task block Topic B?

        # Running task in Topic A
        Task.create!(
          name: "Running in Topic A",
          status: "running",
          trigger_event_name: "comment_created",
          agent: @agent,
          topic_id: @topic_a.id
        )

        # Also a running task in Main (topic_id: nil) — simulating Main topic broadcast
        Task.create!(
          name: "Running in Main",
          status: "running",
          trigger_event_name: "comment_created",
          agent: @agent,
          topic_id: nil
        )

        ResourceTracker.for(@agent).reserve!("job-topic-a")
        ResourceTracker.for(@agent).reserve!("job-main")

        # Schedule in Topic B
        context_b = {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => @topic_b.id }
        }

        scheduler = Scheduler.new(context_b)
        decisions = scheduler.schedule([@agent])

        assert_equal :immediate, decisions.first[:timing],
          "Topic B should not be blocked by Topic A or Main running tasks. " \
          "Got: #{decisions.first[:timing]} (reason: #{decisions.first[:reason]})"
      end

      test "three topics can run in parallel for same agent" do
        topic_c = Topic.create!(name: "Topic C", creative: @creative, user: @user)

        # Running tasks in A and B
        Task.create!(name: "t-a", status: "running", trigger_event_name: "e", agent: @agent, topic_id: @topic_a.id)
        Task.create!(name: "t-b", status: "running", trigger_event_name: "e", agent: @agent, topic_id: @topic_b.id)
        ResourceTracker.for(@agent).reserve!("job-a")
        ResourceTracker.for(@agent).reserve!("job-b")

        # Schedule in Topic C
        context_c = {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => topic_c.id }
        }

        scheduler = Scheduler.new(context_c)
        decisions = scheduler.schedule([@agent])

        assert_equal :immediate, decisions.first[:timing],
          "Third topic should also run in parallel. " \
          "Got: #{decisions.first[:timing]} (reason: #{decisions.first[:reason]})"
      end
    end
  end
end
