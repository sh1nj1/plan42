require "test_helper"

module Collavre
  class CommentLinkPreviewJobTest < ActiveSupport::TestCase
    test "formats matching comment content and persists the preview" do
      owner = users(:one)
      creative = Creative.create!(user: owner, description: "Preview Job")
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      comment = creative.comments.create!(user: owner, content: "https://example.com")
      expected_revision = comment.notification_revision
      clear_enqueued_jobs
      formatter = Minitest::Mock.new
      formatter.expect(:format, "[Example](https://example.com)")

      CommentLinkFormatter.stub(:new, formatter) do
        CommentLinkPreviewJob.perform_now(
          comment.id,
          comment.content,
          comment.notification_revision
        )
      end

      assert_equal "[Example](https://example.com)", comment.reload.content
      assert_equal expected_revision, comment.notification_revision
      assert_no_enqueued_jobs only: CommentLinkPreviewJob
      formatter.verify
    ensure
      clear_enqueued_jobs
      ActiveJob::Base.queue_adapter = original_adapter
    end

    test "does not overwrite content edited after the job was enqueued" do
      owner = users(:one)
      creative = Creative.create!(user: owner, description: "Stale Preview Job")
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      comment = creative.comments.create!(user: owner, content: "https://example.com/old")
      clear_enqueued_jobs
      expected_content = comment.content
      expected_revision = comment.notification_revision
      comment.update_column(:content, "edited content")

      CommentLinkFormatter.stub(:new, ->(*) { flunk("stale content must not be formatted") }) do
        CommentLinkPreviewJob.perform_now(comment.id, expected_content, expected_revision)
      end

      assert_equal "edited content", comment.reload.content
    ensure
      clear_enqueued_jobs
      ActiveJob::Base.queue_adapter = original_adapter
    end

    test "does not overwrite content edited while metadata is being fetched" do
      owner = users(:one)
      creative = Creative.create!(user: owner, description: "Racing Preview Job")
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      comment = creative.comments.create!(user: owner, content: "https://example.com/slow")
      clear_enqueued_jobs
      expected_content = comment.content
      expected_revision = comment.notification_revision
      formatter = Object.new
      formatter.define_singleton_method(:format) do
        comment.update_column(:content, "edited during fetch")
        "[Slow](https://example.com/slow)"
      end

      CommentLinkFormatter.stub(:new, formatter) do
        CommentLinkPreviewJob.perform_now(comment.id, expected_content, expected_revision)
      end

      assert_equal "edited during fetch", comment.reload.content
    ensure
      clear_enqueued_jobs
      ActiveJob::Base.queue_adapter = original_adapter
    end

    test "does not format content changed away and back after enqueue" do
      owner = users(:one)
      creative = Creative.create!(user: owner, description: "ABA Preview Job")
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      comment = creative.comments.create!(user: owner, content: "https://example.com/original")
      expected_content = comment.content
      expected_revision = comment.notification_revision
      clear_enqueued_jobs

      comment.update!(content: "temporarily edited")
      comment.update!(content: expected_content)
      clear_enqueued_jobs

      CommentLinkFormatter.stub(:new, ->(*) { flunk("changed content must not be formatted") }) do
        CommentLinkPreviewJob.perform_now(comment.id, expected_content, expected_revision)
      end

      assert_equal expected_content, comment.reload.content
    ensure
      clear_enqueued_jobs
      ActiveJob::Base.queue_adapter = original_adapter
    end

    test "does nothing when the comment was deleted after enqueue" do
      owner = users(:one)
      creative = Creative.create!(user: owner, description: "Deleted Preview Job")
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      comment = creative.comments.create!(user: owner, content: "https://example.com/deleted")
      expected_content = comment.content
      expected_revision = comment.notification_revision
      comment.destroy!
      clear_enqueued_jobs

      CommentLinkFormatter.stub(:new, ->(*) { flunk("deleted comments must not be formatted") }) do
        assert_nothing_raised do
          CommentLinkPreviewJob.perform_now(comment.id, expected_content, expected_revision)
        end
      end
    ensure
      clear_enqueued_jobs
      ActiveJob::Base.queue_adapter = original_adapter
    end
  end
end
