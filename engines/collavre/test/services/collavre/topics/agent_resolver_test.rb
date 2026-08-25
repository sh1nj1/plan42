# frozen_string_literal: true

require "test_helper"

module Collavre
  module Topics
    class AgentResolverTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = Collavre::Creative.create!(description: "Agent Host", user: @user)
        @agent = create_agent(name: "Reviewer", searchable: true)
      end

      def create_agent(name:, searchable: false, created_by: nil)
        Collavre::User.create!(
          name: name, email: "agent-#{SecureRandom.hex(4)}@test.test", password: "password123",
          llm_vendor: "google", llm_model: "gemini-1.5-flash",
          searchable: searchable, created_by_id: created_by&.id
        )
      end

      test "resolves by id, email and exact name" do
        assert_equal @agent, AgentResolver.call(@agent.id.to_s, actor: @user)
        assert_equal @agent, AgentResolver.call(@agent.email, actor: @user)
        assert_equal @agent, AgentResolver.call("Reviewer", actor: @user)
      end

      test "nil means no change, blank and clear tokens mean unassign" do
        assert_nil AgentResolver.call(nil, actor: @user)
        assert_equal AgentResolver::CLEAR, AgentResolver.call("", actor: @user)
        assert_equal AgentResolver::CLEAR, AgentResolver.call("  ", actor: @user)
        AgentResolver::CLEAR_TOKENS.each do |token|
          assert_equal AgentResolver::CLEAR, AgentResolver.call(token.upcase, actor: @user)
        end
      end

      test "an agent the actor cannot see does not resolve, by id or by name" do
        hidden = create_agent(name: "Hidden")

        assert_raises(AgentResolver::UnknownAgentError) { AgentResolver.call(hidden.id.to_s, actor: @user) }
        assert_raises(AgentResolver::UnknownAgentError) { AgentResolver.call("Hidden", actor: @user) }
      end

      test "an agent created by the actor resolves even when it is not searchable" do
        mine = create_agent(name: "Mine", created_by: @user)

        assert_equal mine, AgentResolver.call("Mine", actor: @user)
      end

      test "a private agent shared on the creative resolves only in that creative" do
        shared = create_agent(name: "Shared Private")
        Collavre::CreativeShare.create!(
          creative: @creative, user: shared, shared_by: @user, permission: :feedback
        )

        assert_equal shared, AgentResolver.call("Shared Private", actor: @user, creative: @creative)
        assert_raises(AgentResolver::UnknownAgentError) do
          AgentResolver.call("Shared Private", actor: @user)
        end
      end

      test "a duplicate name is reported with the candidate ids rather than guessed" do
        twin = create_agent(name: "Reviewer", searchable: true)

        error = assert_raises(AgentResolver::AmbiguousAgentError) { AgentResolver.call("Reviewer", actor: @user) }
        assert_includes error.message, @agent.id.to_s
        assert_includes error.message, twin.id.to_s
      end

      test "a human user is never resolved as an agent" do
        assert_raises(AgentResolver::UnknownAgentError) { AgentResolver.call(users(:two).email, actor: @user) }
      end

      test "an unmatched token explains what is accepted" do
        error = assert_raises(AgentResolver::UnknownAgentError) { AgentResolver.call("nobody", actor: @user) }

        assert_includes error.message, "id, email, or exact name"
      end
    end
  end
end
