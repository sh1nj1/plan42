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
    mock_client = Minitest::Mock.new
    mock_client.expect(:chat, nil) do |messages, **kwargs, &block|
      block.call("This is the AI summary of the conversation.")
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

  test "handles AI failure gracefully" do
    mock_client = Minitest::Mock.new
    mock_client.expect(:chat, nil) do |messages, **kwargs, &block|
      # Return empty (AI failure)
      true
    end

    Collavre::AiClient.stub(:new, mock_client) do
      # Should not raise
      Collavre::CompressJob.perform_now(@creative.id, @topic.id, @user.id)
    end

    # Original comments should still exist
    assert Collavre::Comment.exists?(@comment1.id)
    assert Collavre::Comment.exists?(@comment2.id)
    assert Collavre::Comment.exists?(@comment3.id)
  end
end
