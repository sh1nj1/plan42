require "test_helper"

class Collavre::MergeCommentsJobTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @creative = Collavre::Creative.create!(description: "Merge Job Test", progress: 0.0, user: @user)
    @topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "merge-test")

    @comment1 = @creative.comments.create!(user: @user, content: "First message content", topic: @topic)
    @comment2 = @creative.comments.create!(user: @user, content: "Second message content", topic: @topic)
    @comment3 = @creative.comments.create!(user: @user, content: "Third message content", topic: @topic)
  end

  test "merges comments into the first one and deletes the rest" do
    mock_client = Minitest::Mock.new
    mock_client.expect(:chat, nil) do |messages, **kwargs, &block|
      block.call("Merged: all three messages synthesized into one.")
      true
    end

    Collavre::AiClient.stub(:new, mock_client) do
      Collavre::MergeCommentsJob.perform_now(@creative.id, [ @comment1.id, @comment2.id, @comment3.id ], @user.id)
    end

    # First comment should be updated
    @comment1.reload
    assert_equal "Merged: all three messages synthesized into one.", @comment1.content

    # Rest should be deleted
    assert_not Collavre::Comment.exists?(@comment2.id)
    assert_not Collavre::Comment.exists?(@comment3.id)
  end

  test "does nothing when fewer than 2 comments" do
    Collavre::MergeCommentsJob.perform_now(@creative.id, [ @comment1.id ], @user.id)

    # All comments should still exist unchanged
    assert Collavre::Comment.exists?(@comment1.id)
    assert Collavre::Comment.exists?(@comment2.id)
    assert Collavre::Comment.exists?(@comment3.id)
  end

  test "preserves originals on AI failure (empty response)" do
    mock_client = Minitest::Mock.new
    mock_client.expect(:chat, nil) do |messages, **kwargs, &block|
      # Return empty (AI failure)
      true
    end

    Collavre::AiClient.stub(:new, mock_client) do
      Collavre::MergeCommentsJob.perform_now(@creative.id, [ @comment1.id, @comment2.id, @comment3.id ], @user.id)
    end

    # All original comments should still exist
    assert Collavre::Comment.exists?(@comment1.id)
    assert Collavre::Comment.exists?(@comment2.id)
    assert Collavre::Comment.exists?(@comment3.id)

    # Content should be unchanged
    assert_equal "First message content", @comment1.reload.content
  end

  test "orders comments chronologically and uses the oldest as target" do
    # Create comments in reverse order of IDs but with specific timestamps
    older = @creative.comments.create!(user: @user, content: "Older message", topic: @topic, created_at: 1.hour.ago)
    newer = @creative.comments.create!(user: @user, content: "Newer message", topic: @topic, created_at: Time.current)

    mock_client = Minitest::Mock.new
    mock_client.expect(:chat, nil) do |messages, **kwargs, &block|
      block.call("Merged older and newer.")
      true
    end

    Collavre::AiClient.stub(:new, mock_client) do
      # Pass IDs in non-chronological order
      Collavre::MergeCommentsJob.perform_now(@creative.id, [ newer.id, older.id ], @user.id)
    end

    # Older comment (first chronologically) should be updated
    older.reload
    assert_equal "Merged older and newer.", older.content

    # Newer comment should be deleted
    assert_not Collavre::Comment.exists?(newer.id)
  end

  test "uses topic primary agent when available" do
    ai_agent = Collavre::User.create!(
      name: "Test AI Agent",
      email: "ai-merge-test@example.com",
      password: "password123",
      llm_vendor: "google",
      llm_model: "gemini-3-flash-preview",
      routing_expression: "true"
    )

    Collavre::CreativeShare.create!(
      creative: @creative.effective_origin,
      user: ai_agent,
      permission: :feedback
    )

    Collavre::OrchestratorPolicy.create!(
      policy_type: "arbitration",
      scope_type: "Topic",
      scope_id: @topic.id,
      priority: 10,
      config: { "strategy" => "primary_first", "primary_agent_id" => ai_agent.id },
      enabled: true
    )

    captured_vendor = nil

    mock_client = Minitest::Mock.new
    mock_client.expect(:chat, nil) do |messages, **kwargs, &block|
      block.call("Merged by primary agent.")
      true
    end

    Collavre::AiClient.stub(:new, lambda { |**kwargs|
      captured_vendor = kwargs[:vendor]
      mock_client
    }) do
      Collavre::MergeCommentsJob.perform_now(@creative.id, [ @comment1.id, @comment2.id ], @user.id)
    end

    assert_equal "google", captured_vendor
  end
end
