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

      # --- Review routing (Priority 0) ---

      test "routes review message exclusively to quoted comment author without routing expression" do
        # Summary authored by the AI agent (no routing_expression — setup clears it),
        # as produced by /compress when the agent is resolved via primary_agent_id.
        topic = @creative.topics.create!(name: "Review topic", user: @user)
        summary = @creative.comments.create!(user: @ai_agent, topic_id: topic.id, content: "AI summary")
        review = @creative.comments.create!(
          user: @user, topic_id: topic.id, content: "Make it shorter",
          quoted_comment_id: summary.id
        )

        context = {
          "event_name" => "comment_created",
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => topic.id },
          "comment" => { "id" => review.id },
          "chat" => { "content" => "Make it shorter" }
        }

        # Without Priority 0 this returns [] (no mention, no routing_expression),
        # so the Review button would render but the feedback would never reach
        # the agent that authored the summary.
        assert_equal [ @ai_agent ], Matcher.new(context).match
      end

      test "review routing does not apply to question-type quotes" do
        topic = @creative.topics.create!(name: "Question topic", user: @user)
        summary = @creative.comments.create!(user: @ai_agent, topic_id: topic.id, content: "AI summary")
        question = @creative.comments.create!(
          user: @user, topic_id: topic.id, content: "Why this approach?",
          quoted_comment_id: summary.id, review_type: "question"
        )

        context = {
          "event_name" => "comment_created",
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => topic.id },
          "comment" => { "id" => question.id },
          "chat" => { "content" => "Why this approach?" }
        }

        # A question quote is an ordinary reply: it must fall through to expression
        # routing (no routing_expression here → no match), not hijack to the author.
        assert_empty Matcher.new(context).match
      end

      test "review routing blocks all agents when quoted author lacks permission" do
        other_creative = Creative.create!(user: @user, description: "Other")
        topic = other_creative.topics.create!(name: "No-perm topic", user: @user)
        summary = other_creative.comments.create!(user: @ai_agent, topic_id: topic.id, content: "AI summary")
        review = other_creative.comments.create!(
          user: @user, topic_id: topic.id, content: "Revise",
          quoted_comment_id: summary.id
        )

        context = {
          "event_name" => "comment_created",
          "creative" => { "id" => other_creative.id },
          "topic" => { "id" => topic.id },
          "comment" => { "id" => review.id },
          "chat" => { "content" => "Revise" }
        }

        # Only the author can handle a review; if it can't (no feedback permission
        # on this creative), no other agent should post a stray reply.
        assert_empty Matcher.new(context).match
      end

      test "review routing blocks all agents when quoted comment is ineligible for in-place review" do
        # The quoted comment is private, so ReviewHandler#eligible? rejects it.
        # A review message is finalized through ReviewHandler regardless of which
        # agent the matcher picks (ResponseFinalizer keys on review_message?), so
        # letting it fall through to expression routing would schedule an agent
        # that ReviewHandler#handle then bails on → a stray normal reply. The
        # matcher must BLOCK (return []) an ineligible review, not fall through.
        topic = @creative.topics.create!(name: "Private quote topic", user: @user)
        summary = @creative.comments.create!(
          user: @ai_agent, topic_id: topic.id, content: "AI summary", private: true
        )
        review = @creative.comments.create!(
          user: @user, topic_id: topic.id, content: "Make it shorter",
          quoted_comment_id: summary.id
        )

        # An agent that WOULD match by expression — proves the ineligible review is
        # blocked outright, not merely "no expression happened to match".
        expression_agent = User.create!(
          email: "expr-agent@test.com", password: "password", name: "Expr Agent",
          llm_vendor: "gemini", llm_model: "gemini-3-flash-preview",
          searchable: true, routing_expression: "true"
        )
        CreativeShare.create!(creative: @creative, user: expression_agent, permission: "feedback")
        CreativeSharesCache.find_or_create_by!(
          creative_id: @creative.id, user_id: expression_agent.id, permission: :feedback
        )

        context = {
          "event_name" => "comment_created",
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => topic.id },
          "comment" => { "id" => review.id },
          "chat" => { "content" => "Make it shorter" }
        }

        # Ineligible quote → blocked. The expression_agent must NOT be scheduled,
        # or clicking Review would produce a stray reply from it.
        assert_empty Matcher.new(context).match
      ensure
        expression_agent&.destroy
      end

      # --- Priority ---

      test "mention takes priority over expression matching" do
        other_agent = User.create!(
          email: "other-agent@test.com",
          password: "password",
          name: "Other Agent",
          llm_vendor: "gemini",
          llm_model: "gemini-3-flash-preview",
          searchable: true,
          routing_expression: 'event_name == "comment_created"'
        )
        # Give other_agent permission on creative
        CreativeShare.create!(creative: @creative, user: other_agent, permission: "feedback")

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

      # --- Inbox mention confinement (live Claude Channel session) ---
      #
      # A live Claude Channel session agent holds inbox-wide :feedback +
      # routing_expression="true". The expression path confines it to its own
      # registered session topic so ordinary inbox topics stay identical to a
      # normal topic. The mention path must apply the SAME confinement —
      # otherwise @mentioning the session agent in an ordinary inbox topic would
      # absorb that thread into the live session.

      def build_claude_inbox_session_agent(inbox)
        claude = User.create!(
          email: "matcher_claude_session@agent.collavre.local",
          name: "Claude Session",
          password: "password",
          llm_vendor: "anthropic",
          llm_model: "claude-code",
          routing_expression: "true",
          created_by_id: @user.id
        )
        CreativeShare.find_or_create_by!(creative: inbox, user: claude).update!(permission: "feedback")
        CreativeSharesCache.find_or_create_by!(
          creative_id: inbox.id, user_id: claude.id, permission: :feedback
        )
        claude
      end

      test "mentioned Claude session agent is confined out of an ordinary inbox topic" do
        inbox = Creative.create!(
          description: "Inbox", data: { "kind" => "inbox" }, user: @user, progress: 0.0
        )
        claude = build_claude_inbox_session_agent(inbox)
        ordinary_topic = inbox.topics.create!(name: "Main thread", user: @user)

        context = {
          "event_name" => "comment_created",
          "creative" => { "id" => inbox.id },
          "topic" => { "id" => ordinary_topic.id },
          "chat" => { "mentioned_user" => { "id" => claude.id } }
        }

        # Even on an explicit @mention, an ordinary inbox topic must not route
        # to the live session agent.
        assert_empty Matcher.new(context).match
      end

      test "mentioned Claude session agent matches in its own registered session topic" do
        inbox = Creative.create!(
          description: "Inbox", data: { "kind" => "inbox" }, user: @user, progress: 0.0
        )
        claude = build_claude_inbox_session_agent(inbox)
        session_topic = inbox.topics.create!(name: "Claude session-y", user: @user, session_id: "sess-y")
        session_topic.set_primary_agent!(claude)

        context = {
          "event_name" => "comment_created",
          "creative" => { "id" => inbox.id },
          "topic" => { "id" => session_topic.id },
          "chat" => { "mentioned_user" => { "id" => claude.id } }
        }

        assert_equal [ claude ], Matcher.new(context).match
      end
    end
  end
end
