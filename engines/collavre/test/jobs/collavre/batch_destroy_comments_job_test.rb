# frozen_string_literal: true

require "test_helper"

module Collavre
  class BatchDestroyCommentsJobTest < ActiveJob::TestCase
    setup do
      @owner = users(:one)
      @creative = Creative.create!(user: @owner, description: "Batch job")
      @marked = @creative.comments.create!(user: @owner, content: "Marked", skip_dispatch: true)
      @unmarked = @creative.comments.create!(user: @owner, content: "Unmarked", skip_dispatch: true)
      @marked.update_column(:deleting_at, Time.current)
    end

    test "destroys only comments marked for deletion" do
      BatchDestroyCommentsJob.perform_now([ @marked.id, @unmarked.id ])

      assert_not Comment.exists?(@marked.id)
      assert Comment.exists?(@unmarked.id)
    end

    test "shows a comment again when its destroy is refused" do
      Comment.stub(:destroy_in_batch, ->(_comments) { [] }) do
        BatchDestroyCommentsJob.perform_now([ @marked.id ])
      end

      assert_nil @marked.reload.deleting_at
    end
  end
end
