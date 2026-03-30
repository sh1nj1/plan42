require "test_helper"

class Collavre::MergeCommentsJobTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @creative = Collavre::Creative.create!(description: "Merge Job Test", progress: 0.0, user: @user)
    @topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "merge-test")

    # AI agent is required for merge (same as /compress)
    @ai_agent = Collavre::User.create!(
      name: "Merge AI Agent",
      email: "ai-merge-setup@example.com",
      password: "password123",
      llm_vendor: "google",
      llm_model: "gemini-3-flash-preview"
    )
    Collavre::CreativeShare.create!(
      creative: @creative.effective_origin,
      user: @ai_agent,
      permission: :feedback
    )

    @comment1 = @creative.comments.create!(user: @user, content: "First message content", topic: @topic)
    @comment2 = @creative.comments.create!(user: @user, content: "Second message content", topic: @topic)
    @comment3 = @creative.comments.create!(user: @user, content: "Third message content", topic: @topic)
  end

  test "merges comments into the first one and deletes the rest" do
    merged_text = "Merged: all three messages synthesized into one."
    mock_client = Minitest::Mock.new
    mock_client.expect(:chat, merged_text) do |messages, **kwargs, &block|
      block.call(merged_text)
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

  test "preserves originals when AI returns error text but nil result" do
    # Simulates the bug where AiClient yields error text as delta but returns nil
    mock_client = Minitest::Mock.new
    mock_client.expect(:chat, nil) do |messages, **kwargs, &block|
      block.call("\n\n⚠️ AI Error: OpenClaw Gateway URL not configured")
      true
    end

    Collavre::AiClient.stub(:new, mock_client) do
      Collavre::MergeCommentsJob.perform_now(@creative.id, [ @comment1.id, @comment2.id, @comment3.id ], @user.id)
    end

    # All original comments should still exist — error text must NOT be saved
    assert Collavre::Comment.exists?(@comment1.id)
    assert Collavre::Comment.exists?(@comment2.id)
    assert Collavre::Comment.exists?(@comment3.id)
    assert_equal "First message content", @comment1.reload.content
  end

  test "orders comments chronologically and uses the oldest as target" do
    older = @creative.comments.create!(user: @user, content: "Older message", topic: @topic, created_at: 1.hour.ago)
    newer = @creative.comments.create!(user: @user, content: "Newer message", topic: @topic, created_at: Time.current)

    merged_text = "Merged older and newer."
    mock_client = Minitest::Mock.new
    mock_client.expect(:chat, merged_text) do |messages, **kwargs, &block|
      block.call(merged_text)
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

    @topic.update!(primary_agent_id: ai_agent.id)

    captured_vendor = nil

    merged_text = "Merged by primary agent."
    mock_client = Minitest::Mock.new
    mock_client.expect(:chat, merged_text) do |messages, **kwargs, &block|
      block.call(merged_text)
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

  test "does nothing when no AI agent is available" do
    # Create a creative without any AI agent shared
    creative_no_agent = Collavre::Creative.create!(description: "No Agent", progress: 0.0, user: @user)
    topic = Collavre::Topic.create!(creative: creative_no_agent, user: @user, name: "no-agent-topic")
    c1 = creative_no_agent.comments.create!(user: @user, content: "Message one", topic: topic)
    c2 = creative_no_agent.comments.create!(user: @user, content: "Message two", topic: topic)

    Collavre::MergeCommentsJob.perform_now(creative_no_agent.id, [ c1.id, c2.id ], @user.id)

    # Both comments should still exist unchanged
    assert Collavre::Comment.exists?(c1.id)
    assert Collavre::Comment.exists?(c2.id)
    assert_equal "Message one", c1.reload.content
  end
end
