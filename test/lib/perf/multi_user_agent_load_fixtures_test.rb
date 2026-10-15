# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/perf/multi_user_agent_load").to_s

module Perf
  class MultiUserAgentLoadFixturesTest < ActiveSupport::TestCase
    def prepare(gateway_url: "http://127.0.0.1:9/v1")
      MultiUserAgentLoad::Fixtures.new(user_count: 2, agent_count: 2, gateway_url: gateway_url).prepare!
    end

    test "gives every user one topic per agent, pinned to that agent" do
      fixtures = prepare

      assert_equal 2, fixtures.users.size
      assert fixtures.users.all?(&:email_verified?)
      assert fixtures.agents.all? { |agent| agent.ai_user? && agent.gateway_url == "http://127.0.0.1:9/v1" }
      fixtures.workspaces.each_with_index do |creative, index|
        assert_equal fixtures.users[index], creative.user
        assert_equal fixtures.agents.map(&:id), fixtures.topics[index].map(&:primary_agent_id)
        fixtures.agents.each { |agent| assert creative.has_permission?(agent, :feedback) }
      end
    end

    test "reuses its rows and points agents at the current fake endpoint" do
      first = prepare
      second = prepare(gateway_url: "http://127.0.0.1:10/v1")

      assert_equal first.users.map(&:id), second.users.map(&:id)
      assert_equal first.topics.flatten.map(&:id), second.topics.flatten.map(&:id)
      assert_equal "http://127.0.0.1:10/v1", second.agents.first.reload.gateway_url
    end

    test "cancels turns an aborted run left holding slots" do
      fixtures = prepare
      topic = fixtures.topics.first.first
      leftover = Collavre::Task.create!(
        name: "Leftover", status: "running", trigger_event_name: "comment_created",
        agent: fixtures.agents.first, topic_id: topic.id, creative_id: topic.creative_id,
        trigger_event_payload: { "topic" => { "id" => topic.id } }
      )
      Collavre::Orchestration::ResourceTracker.for(fixtures.agents.first).reserve!(leftover.id)

      prepare

      assert_equal "cancelled", leftover.reload.status
      assert_equal 0, Collavre::Orchestration::ResourceTracker.for(fixtures.agents.first).active_jobs
    end
  end
end
