require "test_helper"

class Collavre::Comments::CompressCommandTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  setup do
    @user = users(:one)
    @creative = Collavre::Creative.create!(description: "Compress Test", progress: 0.0, user: @user)
    @topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "test-compress")
  end

  test "ignores non-compress commands" do
    comment = build_comment(content: "hello world")
    result = Collavre::Comments::CompressCommand.new(comment: comment, user: @user).call
    assert_nil result
  end

  test "returns error when no topic" do
    comment = build_comment(content: "/compress", topic_id: nil)
    result = Collavre::Comments::CompressCommand.new(comment: comment, user: @user).call
    assert_equal I18n.t("collavre.comments.compress_command.topic_required"), result
  end

  test "returns error when topic has no other messages" do
    comment = build_comment(content: "/compress", topic_id: @topic.id)
    result = Collavre::Comments::CompressCommand.new(comment: comment, user: @user).call
    assert_equal I18n.t("collavre.comments.compress_command.nothing_to_compress"), result
  end

  test "returns error when user lacks write permission" do
    @creative.comments.create!(user: @user, content: "first message", topic: @topic)
    @creative.comments.create!(user: @user, content: "second message", topic: @topic)

    unauthorized_user = users(:two)
    comment = build_comment(content: "/compress", topic_id: @topic.id)
    result = Collavre::Comments::CompressCommand.new(comment: comment, user: unauthorized_user).call
    assert_equal I18n.t("collavre.comments.compress_command.not_authorized"), result
  end

  test "enqueues CompressJob when valid" do
    @creative.comments.create!(user: @user, content: "first message", topic: @topic)
    @creative.comments.create!(user: @user, content: "second message", topic: @topic)

    comment = build_comment(content: "/compress", topic_id: @topic.id)

    previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    begin
      assert_enqueued_with(job: Collavre::CompressJob) do
        result = Collavre::Comments::CompressCommand.new(comment: comment, user: @user).call
        assert_equal I18n.t("collavre.comments.compress_command.started"), result
      end
    ensure
      ActiveJob::Base.queue_adapter = previous_adapter
    end
  end

  test "passes extra prompt to job" do
    @creative.comments.create!(user: @user, content: "first message", topic: @topic)
    @creative.comments.create!(user: @user, content: "second message", topic: @topic)

    comment = build_comment(content: "/compress keep action items", topic_id: @topic.id)

    previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    begin
      assert_enqueued_with(job: Collavre::CompressJob) do
        result = Collavre::Comments::CompressCommand.new(comment: comment, user: @user).call
        assert_equal I18n.t("collavre.comments.compress_command.started"), result
      end
    ensure
      ActiveJob::Base.queue_adapter = previous_adapter
    end
  end

  private

  def build_comment(content:, topic_id: @topic.id)
    @creative.comments.build(user: @user, content: content, topic_id: topic_id)
  end
end
