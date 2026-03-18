require "test_helper"

class Collavre::CompressJobTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @creative = Collavre::Creative.create!(description: "Compress Job Test", progress: 0.0, user: @user)
    @topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "compress-job-test")

    @comment1 = @creative.comments.create!(user: @user, content: "First point discussed", topic: @topic)
    @comment2 = @creative.comments.create!(user: @user, content: "Second important decision", topic: @topic)
    @comment3 = @creative.comments.create!(user: @user, content: "Action item: do the thing", topic: @topic)
  end

  test "creates summary and deletes originals" do
    summary_text = "This is the AI summary of the conversation."
    mock_client = Minitest::Mock.new
    mock_client.expect(:chat, summary_text) do |messages, **kwargs, &block|
      block.call(summary_text)
      true
    end

    Collavre::AiClient.stub(:new, mock_client) do
      Collavre::CompressJob.perform_now(@creative.id, @topic.id, @user.id)
    end

    # Original comments should be deleted
    assert_not Collavre::Comment.exists?(@comment1.id)
    assert_not Collavre::Comment.exists?(@comment2.id)
    assert_not Collavre::Comment.exists?(@comment3.id)

    # Summary comment should exist
    summary = @creative.comments.where(topic: @topic).last
    assert summary.present?
    assert_includes summary.content, "This is the AI summary"
    assert_includes summary.content, I18n.t("collavre.comments.compress_command.summary_title", topic: @topic.name)
  end

  test "does nothing when only one comment" do
    @comment2.destroy
    @comment3.destroy

    Collavre::CompressJob.perform_now(@creative.id, @topic.id, @user.id)

    # Original should still exist
    assert Collavre::Comment.exists?(@comment1.id)
  end

  test "uses topic primary agent when OrchestratorPolicy defines one" do
    # Create an AI agent
    ai_agent = Collavre::User.create!(
      name: "Test AI Agent",
      email: "ai-compress-test@example.com",
      password: "password123",
      llm_vendor: "google",
      llm_model: "gemini-3-flash-preview",
      routing_expression: "true"
    )

    # Share the creative with the AI agent
    Collavre::CreativeShare.create!(
      creative: @creative.effective_origin,
      user: ai_agent,
      permission: :feedback
    )

    # Create a topic-level OrchestratorPolicy with primary_agent_id
    Collavre::OrchestratorPolicy.create!(
      policy_type: "arbitration",
      scope_type: "Topic",
      scope_id: @topic.id,
      priority: 10,
      config: { "strategy" => "primary_first", "primary_agent_id" => ai_agent.id },
      enabled: true
    )

    captured_vendor = nil
    captured_model = nil

    mock_client = Minitest::Mock.new
    mock_client.expect(:chat, "Summary from primary agent.") do |messages, **kwargs, &block|
      block.call("Summary from primary agent.")
      true
    end

    Collavre::AiClient.stub(:new, lambda { |**kwargs|
      captured_vendor = kwargs[:vendor]
      captured_model = kwargs[:model]
      mock_client
    }) do
      Collavre::CompressJob.perform_now(@creative.id, @topic.id, @user.id)
    end

    # Verify the primary agent's LLM config was used
    assert_equal "google", captured_vendor
    assert_equal "gemini-3-flash-preview", captured_model
  end

  test "handles AI failure gracefully when chat returns nil with empty summary" do
    mock_client = Minitest::Mock.new
    mock_client.expect(:chat, nil) do |messages, **kwargs, &block|
      # AI returns nothing
      true
    end

    Collavre::AiClient.stub(:new, mock_client) do
      Collavre::CompressJob.perform_now(@creative.id, @topic.id, @user.id)
    end

    # Original comments should still exist
    assert Collavre::Comment.exists?(@comment1.id)
    assert Collavre::Comment.exists?(@comment2.id)
    assert Collavre::Comment.exists?(@comment3.id)
  end

  test "does not delete comments when AI yields error but returns nil" do
    mock_client = Minitest::Mock.new
    mock_client.expect(:chat, nil) do |messages, **kwargs, &block|
      # Simulates OpenClaw adapter: yields error message but returns nil
      block.call("Error: OpenClaw Gateway URL not configured")
      true
    end

    Collavre::AiClient.stub(:new, mock_client) do
      Collavre::CompressJob.perform_now(@creative.id, @topic.id, @user.id)
    end

    # Original comments must NOT be deleted
    assert Collavre::Comment.exists?(@comment1.id)
    assert Collavre::Comment.exists?(@comment2.id)
    assert Collavre::Comment.exists?(@comment3.id)

    # No summary comment should be created
    summary_comments = @creative.comments.where(topic: @topic).where.not(id: [ @comment1.id, @comment2.id, @comment3.id ])
    assert_empty summary_comments
  end
end
