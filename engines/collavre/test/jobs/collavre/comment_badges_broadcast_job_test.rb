# frozen_string_literal: true

require "test_helper"

module Collavre
  # Badge recomputation is O(comment history) per participant. It used to run in
  # the after_commit of the comment that triggered it, so posting a message got
  # slower for everyone as a conversation grew. These pin the seam: the callback
  # only enqueues, and the arithmetic lives in the job.
  class CommentBadgesBroadcastJobTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      @creative = Creative.create!(user: @user, description: "Badge job", sequence: 940)
    end

    test "creating a comment enqueues the badge broadcast instead of computing it inline" do
      with_test_queue_adapter do
        assert_enqueued_with(job: CommentBadgesBroadcastJob, args: [ @creative.id ]) do
          Comment.create!(creative: @creative, user: @user, content: "hello")
        end
      end
    end

    test "destroying a comment enqueues the badge broadcast too" do
      comment = Comment.create!(creative: @creative, user: @user, content: "bye")

      with_test_queue_adapter do
        assert_enqueued_with(job: CommentBadgesBroadcastJob, args: [ @creative.id ]) do
          comment.destroy!
        end
      end
    end

    test "the job recomputes badges for the creative" do
      received = []
      Comment.stub(:broadcast_badges, ->(creative) { received << creative.id }) do
        CommentBadgesBroadcastJob.perform_now(@creative.id)
      end

      assert_equal [ @creative.id ], received
    end

    # A comment can be destroyed together with its creative; by the time the job
    # runs the creative is gone and there is nothing left to recount.
    test "a job for a creative that no longer exists is a no-op" do
      missing_id = Creative.maximum(:id).to_i + 1_000

      called = false
      Comment.stub(:broadcast_badges, ->(_creative) { called = true }) do
        assert_nothing_raised { CommentBadgesBroadcastJob.perform_now(missing_id) }
      end

      refute called
    end

    private

    def with_test_queue_adapter
      saved_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      yield
    ensure
      ActiveJob::Base.queue_adapter = saved_adapter
    end
  end
end
