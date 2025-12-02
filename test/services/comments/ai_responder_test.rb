require "test_helper"

module Comments
  class AiResponderTest < ActiveSupport::TestCase
    test "updates placeholder with error when AI client fails" do
      creative = creatives(:tshirt)
      commenter = users(:one)
      ai_user = User.create!(
        name: "AIBot",
        email: "aibot@example.com",
        password: "password",
        llm_vendor: "google",
        llm_model: "gemini-2.5-flash",
        system_prompt: "You are a bot.",
        llm_api_key: "dummy-key",
        email_verified_at: Time.current,
        searchable: true
      )

      comment = creative.comments.create!(content: "@AIBot: ping", user: commenter)

      failing_client = Minitest::Mock.new
      failing_client.expect(:chat, nil) do |_messages, &block|
        raise StandardError, "boom"
      end

      AiClient.stub(:new, failing_client) do
        Comments::AiResponder.new(comment: comment, creative: creative).call
      end

      reply = creative.comments.where(user: ai_user).order(:id).last
      assert_equal "AI Error: boom", reply.content
    end

    test "responds to ai mention when ai user has feedback access but is not searchable" do
      creative = Creative.create!(user: users(:one), description: "AI mention creative")
      commenter = users(:two)
      ai_user = User.create!(
        name: "AIBuddy",
        email: "aibuddy@example.com",
        password: "password",
        llm_vendor: "google",
        llm_model: "gemini-2.5-flash",
        system_prompt: "You are a bot.",
        llm_api_key: "dummy-key",
        searchable: false,
        email_verified_at: Time.current
      )
      CreativeShare.create!(creative: creative, user: ai_user, permission: :feedback)

      comment = creative.comments.create!(content: "@AIBuddy: ping", user: commenter)

      fake_client = Class.new do
        def initialize(**_args); end
        def chat(_messages, tools: [])
          yield "pong" if block_given?
        end
      end

      AiClient.stub(:new, fake_client.new) do
        Comments::AiResponder.new(comment: comment, creative: creative).call
      end

      reply = creative.comments.where(user: ai_user).order(:id).last
      assert_equal "pong", reply.content
    end

    test "renders liquid variables in system prompt" do
      creative = creatives(:tshirt)
      commenter = users(:one)
      ai_user = User.create!(
        name: "AIBot",
        email: "aibot@example.com",
        password: "password",
        llm_vendor: "google",
        llm_model: "gemini-2.5-flash",
        system_prompt: "Assist {{ai_user.name}} on {{creative.description}} for {{comment.user_name}} about {{payload}}",
        llm_api_key: "dummy-key",
        email_verified_at: Time.current,
        searchable: true
      )

      comment = creative.comments.create!(content: "@AIBot: ping please", user: commenter)

      captured_prompt = nil
      fake_client = Class.new do
        attr_reader :system_prompt

        def initialize(**args)
          @system_prompt = args[:system_prompt]
        end

        def chat(_messages, tools: [])
          yield "pong" if block_given?
          "pong"
        end
      end

      AiClient.stub(:new, ->(**args) { instance = fake_client.new(**args); captured_prompt = instance.system_prompt; instance }) do
        Comments::AiResponder.new(comment: comment, creative: creative).call
      end

      assert_equal "Assist AIBot on T-Shirt for One about ping please", captured_prompt
      reply = creative.comments.where(user: ai_user).order(:id).last
      assert_equal "pong", reply.content
    end
  end
end
