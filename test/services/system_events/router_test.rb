require "test_helper"

module SystemEvents
  class RouterTest < ActiveSupport::TestCase
    setup do
      @owner = users(:one)
      @creative = Creative.create!(user: @owner, description: "Test Description")

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

    test "routes event to agent when expression evaluates to true" do
      router = SystemEvents::Router.new
      agents = router.route("comment_created", @context)

      assert_includes agents, @agent
    end

    test "does not route event when expression evaluates to false" do
      @agent.update!(routing_expression: "false")

      router = SystemEvents::Router.new
      agents = router.route("comment_created", @context)

      assert_not_includes agents, @agent
    end

    test "skips non-searchable agent without permission" do
      @agent.update!(searchable: false, routing_expression: "true")

      router = SystemEvents::Router.new
      agents = router.route("comment_created", @context)

      assert_not_includes agents, @agent
    end

    test "routes non-searchable agent with permission" do
      @agent.update!(searchable: false, routing_expression: "true")
      CreativeShare.create!(creative: @creative, user: @agent, permission: :feedback, shared_by: @owner)

      router = SystemEvents::Router.new
      agents = router.route("comment_created", @context)

      assert_includes agents, @agent
    end

    test "handles liquid error gracefully" do
      @agent.update!(routing_expression: "{{ invalid syntax }")

      assert_nothing_raised do
        router = SystemEvents::Router.new
        agents = router.route("comment_created", @context)
        assert_not_includes agents, @agent
      end
    end

    test "routes based on event_name" do
      @agent.update!(routing_expression: "event_name == 'comment_created'")

      router = SystemEvents::Router.new
      agents = router.route("comment_created", @context)

      assert_includes agents, @agent

      agents = router.route("other_event", @context)
      assert_not_includes agents, @agent
    end
  end
end
