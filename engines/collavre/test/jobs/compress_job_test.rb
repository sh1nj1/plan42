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
    create_ai_agent_for_creative

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

  test "summary comment is authored by the AI agent so the review button shows" do
    agent = create_ai_agent_for_creative

    summary_text = "This is the AI summary of the conversation."
    mock_client = Minitest::Mock.new
    mock_client.expect(:chat, summary_text) do |messages, **kwargs, &block|
      block.call(summary_text)
      true
    end

    Collavre::AiClient.stub(:new, mock_client) do
      Collavre::CompressJob.perform_now(@creative.id, @topic.id, @user.id)
    end

    summary = @creative.comments.where(topic: @topic).last
    assert summary.present?
    # Authored by the AI agent, not the human who ran /compress.
    assert_equal agent, summary.user
    # ai_user? is what gates the "Review" button in _comment.html.erb.
    assert summary.user.ai_user?, "summary author must be an AI user for the review button to render"
  end

  test "summary survives and snapshot keeps its restore anchor when the authoring agent is deleted" do
    agent = create_ai_agent_for_creative

    summary_text = "This is the AI summary of the conversation."
    mock_client = Minitest::Mock.new
    mock_client.expect(:chat, summary_text) do |messages, **kwargs, &block|
      block.call(summary_text)
      true
    end

    Collavre::AiClient.stub(:new, mock_client) do
      Collavre::CompressJob.perform_now(@creative.id, @topic.id, @user.id)
    end

    summary = @creative.comments.where(topic: @topic).last
    snapshot = Collavre::CommentSnapshot.find_by!(result_comment_id: summary.id)

    # Deleting the agent must NOT cascade-destroy the durable summary, which would
    # orphan the snapshot and erase the only restore path for the conversation.
    agent.destroy!

    assert Collavre::Comment.exists?(summary.id), "summary comment must survive agent deletion"
    assert_nil summary.reload.user_id, "author is detached, not the comment destroyed"
    assert_equal summary.id, snapshot.reload.result_comment_id, "snapshot keeps its restore anchor"
    assert snapshot.restorable?, "snapshot remains restorable"
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

    # Set primary agent directly on topic
    @topic.update!(primary_agent_id: ai_agent.id)

    captured_vendor = nil
    captured_model = nil
    captured_context = nil

    summary_text = "Summary from primary agent."
    mock_client = Minitest::Mock.new
    mock_client.expect(:chat, summary_text) do |messages, **kwargs, &block|
      block.call(summary_text)
      true
    end

    Collavre::AiClient.stub(:new, lambda { |**kwargs|
      captured_vendor = kwargs[:vendor]
      captured_model = kwargs[:model]
      captured_context = kwargs[:context]
      mock_client
    }) do
      Collavre::CompressJob.perform_now(@creative.id, @topic.id, @user.id)
    end

    # Verify the primary agent's LLM config was used
    assert_equal "google", captured_vendor
    assert_equal "gemini-3-flash-preview", captured_model

    # Verify context includes the agent user (needed for OpenClaw adapter)
    assert_equal ai_agent, captured_context[:user]
    assert_equal @creative, captured_context[:creative]
    assert_equal @topic.id, captured_context[:topic_id]
  end

  test "shows error message when no AI agent is available" do
    # No AI agent shared with this creative
    initial_count = @creative.comments.where(topic: @topic).count

    Collavre::CompressJob.perform_now(@creative.id, @topic.id, @user.id)

    # Original comments should still exist
    assert Collavre::Comment.exists?(@comment1.id)
    assert Collavre::Comment.exists?(@comment2.id)
    assert Collavre::Comment.exists?(@comment3.id)

    # An error comment should be created
    error_comment = @creative.comments.where(topic: @topic).order(created_at: :desc).first
    assert_includes error_comment.content, I18n.t("collavre.comments.compress_command.no_agent")
    assert_equal initial_count + 1, @creative.comments.where(topic: @topic).count
  end

  test "handles AI failure gracefully when chat returns nil with empty summary" do
    create_ai_agent_for_creative

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

  test "preserves originals when AI returns error text but nil result" do
    create_ai_agent_for_creative

    mock_client = Minitest::Mock.new
    mock_client.expect(:chat, nil) do |messages, **kwargs, &block|
      # Simulates OpenClaw adapter: yields error message but returns nil
      block.call("Error: OpenClaw Gateway URL not configured")
      true
    end

    Collavre::AiClient.stub(:new, mock_client) do
      Collavre::CompressJob.perform_now(@creative.id, @topic.id, @user.id)
    end

    # Original comments must NOT be deleted — error text should not be treated as summary
    assert Collavre::Comment.exists?(@comment1.id)
    assert Collavre::Comment.exists?(@comment2.id)
    assert Collavre::Comment.exists?(@comment3.id)

    # No summary comment should be created
    summary_comments = @creative.comments.where(topic: @topic).where.not(id: [ @comment1.id, @comment2.id, @comment3.id ])
    assert_empty summary_comments
  end

  test "does not persist a summary when the topic moves during the AI call" do
    create_ai_agent_for_creative
    destination = Collavre::Creative.create!(description: "Moved compression", user: @user)
    mock_client = Minitest::Mock.new
    mock_client.expect(:chat, "summary") do |_messages, **_kwargs, &block|
      block.call("summary")
      Collavre::Topics::TopicMove.new(topic: @topic, target_creative: destination).call
      true
    end

    Collavre::AiClient.stub(:new, mock_client) do
      Collavre::CompressJob.perform_now(@creative.id, @topic.id, @user.id)
    end

    assert_equal destination.id, @topic.reload.creative_id
    assert_equal [ @comment1.id, @comment2.id, @comment3.id ].sort,
                 destination.comments.where(topic: @topic).pluck(:id).sort
    assert_not Collavre::CommentSnapshot.where(topic: @topic).exists?
  end

  private

  def create_ai_agent_for_creative
    agent = Collavre::User.create!(
      name: "Compress AI Agent",
      email: "ai-compress-helper@example.com",
      password: "password123",
      llm_vendor: "google",
      llm_model: "gemini-3-flash-preview",
      routing_expression: "true"
    )
    Collavre::CreativeShare.create!(
      creative: @creative.effective_origin,
      user: agent,
      permission: :feedback
    )
    agent
  end
end
