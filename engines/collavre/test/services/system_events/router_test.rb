require "test_helper"

module SystemEvents
  class RouterTest < ActiveSupport::TestCase
    setup do
      @owner = users(:one)
      perform_enqueued_jobs do
        @creative = Creative.create!(user: @owner, description: "Test Description")
      end

      @agent = User.create!(
        email: "router_test_agent@example.com",
        name: "Router Agent",
        password: "password",
        llm_vendor: "google",
        llm_model: "gemini-1.5-flash",
        routing_expression: "chat.mentioned_user.id == agent.id",
        searchable: true
      )

      @context = {
        "creative" => { "id" => @creative.id },
        "chat" => {
          "content" => "@Router Agent: Hello",
          "mentioned_user" => { "id" => @agent.id }
        }
      }
    end

    # ========================================
    # Mention-based Routing (Priority 1)
    # ========================================

    test "mention routing: routes exclusively to mentioned AI agent" do
      # Create another agent that would match via Liquid expression
      other_agent = User.create!(
        email: "other_agent@example.com",
        name: "Other Agent",
        password: "password",
        llm_vendor: "google",
        llm_model: "gemini-1.5-flash",
        routing_expression: "true", # This would always match
        searchable: true
      )

      router = SystemEvents::Router.new
      agents = router.route("comment_created", @context)

      # Only the mentioned agent should receive the message
      assert_equal 1, agents.length
      assert_includes agents, @agent
      assert_not_includes agents, other_agent
    end

    test "mention routing: ignores liquid expressions when agent is mentioned" do
      # Even with routing_expression: "false", mentioned agent should receive
      @agent.update!(routing_expression: "false")

      router = SystemEvents::Router.new
      agents = router.route("comment_created", @context)

      assert_includes agents, @agent
    end

    test "mention routing: skips mentioned non-AI user" do
      # Create a regular user (not an AI agent)
      regular_user = User.create!(
        email: "regular@example.com",
        name: "Regular User",
        password: "password",
        searchable: true
      )

      context = {
        "creative" => { "id" => @creative.id },
        "chat" => {
          "content" => "@Regular User: Hello",
          "mentioned_user" => { "id" => regular_user.id }
        }
      }

      # Create an agent with "true" routing expression as fallback
      @agent.update!(routing_expression: "true")

      router = SystemEvents::Router.new
      agents = router.route("comment_created", context)

      # Should fall back to Liquid routing
      assert_includes agents, @agent
    end

    test "mention routing: respects permission for non-searchable mentioned agent" do
      @agent.update!(searchable: false)

      router = SystemEvents::Router.new
      agents = router.route("comment_created", @context)

      # Mentioned but no permission - should not route
      assert_not_includes agents, @agent
    end

    test "mention routing: routes to non-searchable mentioned agent with permission" do
      @agent.update!(searchable: false)
      perform_enqueued_jobs do
        CreativeShare.create!(creative: @creative, user: @agent, permission: :feedback, shared_by: @owner)
      end

      router = SystemEvents::Router.new
      agents = router.route("comment_created", @context)

      assert_includes agents, @agent
    end

    # ========================================
    # Liquid Expression Routing (Priority 2)
    # ========================================

    test "liquid routing: routes event to agent when expression evaluates to true" do
      # No mention in context
      context = {
        "creative" => { "id" => @creative.id },
        "chat" => { "content" => "Hello world" }
      }
      @agent.update!(routing_expression: "true")

      router = SystemEvents::Router.new
      agents = router.route("comment_created", context)

      assert_includes agents, @agent
    end

    test "liquid routing: does not route event when expression evaluates to false" do
      context = {
        "creative" => { "id" => @creative.id },
        "chat" => { "content" => "Hello world" }
      }
      @agent.update!(routing_expression: "false")

      router = SystemEvents::Router.new
      agents = router.route("comment_created", context)

      assert_not_includes agents, @agent
    end

    test "liquid routing: skips non-searchable agent without permission" do
      context = {
        "creative" => { "id" => @creative.id },
        "chat" => { "content" => "Hello world" }
      }
      @agent.update!(searchable: false, routing_expression: "true")

      router = SystemEvents::Router.new
      agents = router.route("comment_created", context)

      assert_not_includes agents, @agent
    end

    test "liquid routing: routes non-searchable agent with permission" do
      context = {
        "creative" => { "id" => @creative.id },
        "chat" => { "content" => "Hello world" }
      }
      @agent.update!(searchable: false, routing_expression: "true")
      perform_enqueued_jobs do
        CreativeShare.create!(creative: @creative, user: @agent, permission: :feedback, shared_by: @owner)
      end

      router = SystemEvents::Router.new
      agents = router.route("comment_created", context)

      assert_includes agents, @agent
    end

    test "liquid routing: handles liquid error gracefully" do
      @agent.update!(routing_expression: "{{ invalid syntax }")

      assert_nothing_raised do
        router = SystemEvents::Router.new
        agents = router.route("comment_created", @context)
        # Still routes via mention even if liquid is broken
        assert_includes agents, @agent
      end
    end

    test "liquid routing: routes based on event_name" do
      context = {
        "creative" => { "id" => @creative.id },
        "chat" => { "content" => "Hello world" }
      }
      @agent.update!(routing_expression: "event_name == 'comment_created'")

      router = SystemEvents::Router.new
      agents = router.route("comment_created", context)

      assert_includes agents, @agent

      agents = router.route("other_event", context)
      assert_not_includes agents, @agent
    end

    test "liquid routing: can route to multiple agents" do
      context = {
        "creative" => { "id" => @creative.id },
        "chat" => { "content" => "Hello world" }
      }
      @agent.update!(routing_expression: "true")

      other_agent = User.create!(
        email: "other_agent@example.com",
        name: "Other Agent",
        password: "password",
        llm_vendor: "google",
        llm_model: "gemini-1.5-flash",
        routing_expression: "true",
        searchable: true
      )

      router = SystemEvents::Router.new
      agents = router.route("comment_created", context)

      assert_equal 2, agents.length
      assert_includes agents, @agent
      assert_includes agents, other_agent
    end
  end
end
