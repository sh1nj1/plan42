# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    class MatcherTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @ai_agent = users(:ai_bot)
        @creative = creatives(:tshirt)

        # Default to searchable for most tests (permission tests override this)
        @ai_agent.update!(searchable: true)

        # Grant feedback permission on the creative for AI agent
        # (searchable only affects discoverability, not response permission)
        share = CreativeShare.find_or_create_by!(creative: @creative, user: @ai_agent)
        share.update!(permission: "feedback")
        # Manually create cache entry (after_commit doesn't run in test transaction)
        CreativeSharesCache.find_or_create_by!(
          creative_id: @creative.id,
          user_id: @ai_agent.id,
          permission: :feedback
        )

        # Clear any existing routing expressions
        User.where.not(llm_vendor: nil).update_all(routing_expression: nil)
      end

      # --- Mention-based routing ---

      test "matches mentioned AI agent" do
        context = {
          "event_name" => "comment_created",
          "creative" => { "id" => @creative.id },
          "chat" => {
            "mentioned_user" => { "id" => @ai_agent.id }
          }
        }

        result = Matcher.new(context).match
        assert_equal [ @ai_agent ], result
      end

      test "returns empty array when human is mentioned" do
        context = {
          "event_name" => "comment_created",
          "creative" => { "id" => @creative.id },
          "chat" => {
            "mentioned_user" => { "id" => @user.id }
          }
        }

        result = Matcher.new(context).match
        assert_empty result
      end

      test "returns empty array when mentioned AI agent lacks permission" do
        @ai_agent.update!(searchable: false)
        other_creative = Creative.create!(user: @user, description: "Other")

        context = {
          "event_name" => "comment_created",
          "creative" => { "id" => other_creative.id },
          "chat" => {
            "mentioned_user" => { "id" => @ai_agent.id }
          }
        }

        result = Matcher.new(context).match
        assert_empty result
      end

      # --- Expression-based routing ---

      test "matches agent with matching routing expression" do
        @ai_agent.update!(routing_expression: 'event_name == "comment_created"')

        context = {
          "event_name" => "comment_created",
          "creative" => { "id" => @creative.id },
          "chat" => {}
        }

        result = Matcher.new(context).match
        assert_includes result, @ai_agent
      end

      test "does not match agent with non-matching expression" do
        @ai_agent.update!(routing_expression: 'event_name == "other_event"')

        context = {
          "event_name" => "comment_created",
          "creative" => { "id" => @creative.id },
          "chat" => {}
        }

        result = Matcher.new(context).match
        assert_not_includes result, @ai_agent
      end

      test "matches agent with complex Liquid expression" do
        @ai_agent.update!(
          routing_expression: 'chat.content contains "help" and event_name == "comment_created"'
        )

        context = {
          "event_name" => "comment_created",
          "creative" => { "id" => @creative.id },
          "chat" => { "content" => "I need help with this" }
        }

        result = Matcher.new(context).match
        assert_includes result, @ai_agent
      end

      test "agent can reference itself in expression" do
        @ai_agent.update!(routing_expression: "agent.id == #{@ai_agent.id}")

        context = {
          "event_name" => "comment_created",
          "creative" => { "id" => @creative.id },
          "chat" => {}
        }

        result = Matcher.new(context).match
        assert_includes result, @ai_agent
      end

      test "handles invalid Liquid expression gracefully" do
        @ai_agent.update!(routing_expression: "{% invalid %}")

        context = {
          "event_name" => "comment_created",
          "creative" => { "id" => @creative.id },
          "chat" => {}
        }

        # Should not raise, just return empty
        result = Matcher.new(context).match
        assert_not_includes result, @ai_agent
      end

      # --- Permission checks ---

      test "searchable agent does NOT match without creative permission" do
        @ai_agent.update!(searchable: true, routing_expression: 'event_name == "comment_created"')
        other_creative = Creative.create!(user: @user, description: "Other")
        # No permission granted on other_creative

        context = {
          "event_name" => "comment_created",
          "creative" => { "id" => other_creative.id },
          "chat" => {}
        }

        result = Matcher.new(context).match
        # searchable only affects discoverability, not response permission
        assert_not_includes result, @ai_agent
      end

      test "non-searchable agent requires creative permission" do
        @ai_agent.update!(searchable: false, routing_expression: 'event_name == "comment_created"')
        other_creative = Creative.create!(user: @user, description: "Other")

        context = {
          "event_name" => "comment_created",
          "creative" => { "id" => other_creative.id },
          "chat" => {}
        }

        result = Matcher.new(context).match
        assert_not_includes result, @ai_agent
      end

      # --- Priority ---

      test "mention takes priority over expression matching" do
        other_agent = User.create!(
          email: "other-agent@test.com",
          password: "password",
          name: "Other Agent",
          llm_vendor: "gemini",
          llm_model: "gemini-2.5-flash",
          searchable: true,
          routing_expression: 'event_name == "comment_created"'
        )

        context = {
          "event_name" => "comment_created",
          "creative" => { "id" => @creative.id },
          "chat" => {
            "mentioned_user" => { "id" => @ai_agent.id }
          }
        }

        result = Matcher.new(context).match

        # Only mentioned agent, not the one matching by expression
        assert_equal [ @ai_agent ], result
      ensure
        other_agent&.destroy
      end
    end
  end
end
