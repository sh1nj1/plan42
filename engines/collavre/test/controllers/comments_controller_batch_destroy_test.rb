# frozen_string_literal: true

require "test_helper"

class CommentsControllerBatchDestroyTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @owner = users(:one)
    @member = users(:two)
    @creative = creatives(:tshirt)
    [ @owner, @member ].each { |user| user.update!(email_verified_at: Time.current) }
    perform_enqueued_jobs { Collavre::CreativeShare.create!(creative: @creative, user: @member, permission: :feedback) }

    @mine = @creative.comments.create!(content: "Mine", user: @member)
    @also_mine = @creative.comments.create!(content: "Also mine", user: @member)
    @theirs = @creative.comments.create!(content: "Theirs", user: @owner)
  end

  teardown do
    ActiveJob::Base.queue_adapter = @original_adapter
  end

  test "hides the selection at once and destroys it in the background" do
    sign_in_as(@member)

    assert_enqueued_with(job: Collavre::BatchDestroyCommentsJob, args: [ [ @mine.id, @also_mine.id ] ]) do
      delete batch_destroy_creative_comments_path(@creative), params: { comment_ids: [ @mine.id, @also_mine.id ] }, as: :json
    end

    assert_response :no_content
    assert @mine.reload.deleting_at
    assert @also_mine.reload.deleting_at
    assert_empty @creative.comments.visible_to(@member).where(id: [ @mine.id, @also_mine.id ])
    assert_nil @theirs.reload.deleting_at

    perform_enqueued_jobs(only: Collavre::BatchDestroyCommentsJob)
    assert_not Collavre::Comment.exists?(@mine.id)
    assert_not Collavre::Comment.exists?(@also_mine.id)
  end

  test "broadcasts the removal before the job runs" do
    sign_in_as(@member)
    streams = []
    capture = ->(stream, content:) { streams << [ stream, content ] if stream == [ @creative, :comments ] }

    Turbo::StreamsChannel.stub(:broadcast_stream_to, capture) do
      delete batch_destroy_creative_comments_path(@creative), params: { comment_ids: [ @mine.id ] }, as: :json
    end

    assert_equal 1, streams.size
    assert_includes streams.first.last, "comment_#{@mine.id}"
  end

  test "refuses another user's comments for a non-admin" do
    sign_in_as(@member)

    assert_no_enqueued_jobs(only: Collavre::BatchDestroyCommentsJob) do
      delete batch_destroy_creative_comments_path(@creative), params: { comment_ids: [ @mine.id, @theirs.id ] }, as: :json
    end

    assert_response :forbidden
    assert_nil @mine.reload.deleting_at
  end

  test "creative owner may delete anyone's comments" do
    sign_in_as(@owner)

    delete batch_destroy_creative_comments_path(@creative), params: { comment_ids: [ @mine.id, @theirs.id ] }, as: :json

    assert_response :no_content
    assert @mine.reload.deleting_at
    assert @theirs.reload.deleting_at
  end

  test "a comment already being deleted is not found again" do
    sign_in_as(@member)
    @mine.update_column(:deleting_at, Time.current)

    delete batch_destroy_creative_comments_path(@creative), params: { comment_ids: [ @mine.id ] }, as: :json

    assert_response :not_found
  end

  test "an empty selection is rejected" do
    sign_in_as(@member)

    delete batch_destroy_creative_comments_path(@creative), params: { comment_ids: [] }, as: :json

    assert_response :unprocessable_entity
  end

  private

  def sign_in_as(user)
    post session_path, params: { email: user.email, password: "password" }
  end
end
