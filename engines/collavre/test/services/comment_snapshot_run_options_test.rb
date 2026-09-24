require "test_helper"

module Collavre
  class CommentSnapshotRunOptionsTest < ActiveSupport::TestCase
    test "snapshot round trip preserves human overrides and AI audit options" do
      user = users(:one)
      creative = Creative.create!(user: user, description: "Snapshot options")
      options = { "model" => "paperclip/claude_local/opus", "reasoning_effort" => "max" }
      comments = [ user, users(:ai_bot) ].map do |author|
        creative.comments.create!(user: author, content: "Message", agent_run_options: options, skip_dispatch: true)
      end
      serializer = Object.new.extend(CommentSerializable)
      data = serializer.send(:serialize_comments, comments)
      assert_equal [ options, options ], data.map { |item| item["agent_run_options"] }
      snapshot = CommentSnapshot.create!(creative: creative, user: user, operation: "compress", comments_data: data)
      comments.each(&:destroy!)
      restored = CommentSnapshotRestoreService.new(snapshot: snapshot, user: user).call
      assert_equal [ options, options ], restored.map { |comment| comment.reload.agent_run_options }
      assert_equal [ user.id, users(:ai_bot).id ], restored.map(&:user_id)
    end

    test "legacy snapshots without run options still restore" do
      user = users(:one)
      creative = Creative.create!(user: user, description: "Legacy snapshot")
      snapshot = CommentSnapshot.create!(creative: creative, user: user, operation: "merge",
                                        comments_data: [ { "id" => 1, "user_id" => user.id, "content" => "Legacy" } ])
      restored = CommentSnapshotRestoreService.new(snapshot: snapshot, user: user).call
      assert_nil restored.first.reload.agent_run_options
    end
  end
end
