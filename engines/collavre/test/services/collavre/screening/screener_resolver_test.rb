# frozen_string_literal: true

require "test_helper"
require_relative "screening_test_support"

module Collavre
  module Screening
    class ScreenerResolverTest < ActiveSupport::TestCase
      include ScreeningTestSupport

      setup do
        @owner = users(:one)
        @admin = users(:two)
        @parent = Creative.create!(description: "Shared parent", user: @admin)
        @child = Creative.create!(description: "Shared child", user: @admin, parent: @parent)
        @agent = create_agent(@owner, name: "Protected")
        @task = Task.create!(name: "Screen", agent: @agent, status: "running")
      end

      def ids(screeners) = screeners.map(&:id)

      test "system screener by default" do
        assert_equal [ "system" ], ids(ScreenerResolver.for(agent: @agent, creative: @child, task: @task))
        assert_equal [ "system" ], ids(ScreenerResolver.for(agent: @agent, creative: nil, task: @task))
      end

      test "the owner's own judge on an ancestor replaces the system screener" do
        judge = create_agent(@owner, name: "OwnerJudge", vendor: "typesafe", model: "jev-latest")
        CreativeShare.create!(creative: @parent, user: judge, permission: :feedback)
        assert_equal [ "agent:#{judge.id}" ], ids(ScreenerResolver.for(agent: @agent, creative: @child, task: @task))
      end

      test "someone else's judge screens alongside the system screener" do
        judge = create_agent(@admin, name: "AdminJudge", vendor: "typesafe", model: "jev-latest")
        CreativeShare.create!(creative: @child, user: judge, permission: :feedback)
        assert_equal [ "system", "agent:#{judge.id}" ], ids(ScreenerResolver.for(agent: @agent, creative: @child, task: @task))
      end

      test "an ownerless agent never hands screening to a judge" do
        @agent.update_columns(created_by_id: nil)
        judge = create_agent(nil, name: "Orphan", vendor: "typesafe", model: "jev-latest")
        CreativeShare.create!(creative: @child, user: judge, permission: :feedback)
        assert_equal [ "system", "agent:#{judge.id}" ], ids(ScreenerResolver.for(agent: @agent.reload, creative: @child, task: @task))
      end

      test "judges below feedback, chat-only agents and the protected agent itself are ignored" do
        reader = create_agent(@owner, name: "Reader", vendor: "typesafe", model: "jev-latest")
        CreativeShare.create!(creative: @child, user: reader, permission: :read)
        CreativeShare.create!(creative: @child, user: create_agent(@owner, name: "Chatty"), permission: :feedback)
        assert_equal [ "system" ], ids(ScreenerResolver.for(agent: @agent, creative: @child, task: @task))
      end

      test "a share the live permission check rejects is ignored" do
        judge = create_agent(@owner, name: "Revoked", vendor: "typesafe", model: "jev-latest")
        CreativeShare.create!(creative: @child, user: judge, permission: :feedback)
        Creatives::PermissionChecker.stub(:current_allowed?, false) do
          assert_equal [ "system" ], ids(ScreenerResolver.for(agent: @agent, creative: @child, task: @task))
        end
      end
    end
  end
end
