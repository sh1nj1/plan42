require "test_helper"

module CollavreOpenclaw
  class ProcessedAiRunTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "par-test@example.com", password: "password123", name: "PAR Bot")
      @creative = Collavre::Creative.create!(description: "PAR Creative", user: @user)
    end

    teardown do
      CollavreOpenclaw::ProcessedAiRun.where(run_id: %w[r1 r2 r-folded r-race]).delete_all
      Collavre::Comment.where(creative: @creative).destroy_all
      @creative&.destroy
      @user&.destroy
    end

    test "processed? is false until a run is recorded, true after" do
      assert_not ProcessedAiRun.processed?("r1")
      assert ProcessedAiRun.claim_proactive("r1", make_comment)
      assert ProcessedAiRun.processed?("r1")
    end

    test "claim_proactive returns false on a lost race (run already claimed)" do
      assert ProcessedAiRun.claim_proactive("r2", make_comment)
      assert_not ProcessedAiRun.claim_proactive("r2", make_comment),
                 "second claim of the same run loses the race"
      assert_equal 1, ProcessedAiRun.where(run_id: "r2").count
    end

    test "blank run_id is never processed and claim is a no-op" do
      assert_not ProcessedAiRun.processed?(nil)
      assert_not ProcessedAiRun.processed?("")
      assert ProcessedAiRun.claim_proactive(nil, make_comment), "blank claim is a benign no-op"
      assert_equal 0, ProcessedAiRun.where(run_id: nil).count
    end

    test "the run row survives comment destruction as a durable tombstone" do
      # Mirrors the review workflow folding+destroying the solicited reply: the
      # comment goes away but the run must stay recognized as already-handled.
      comment = make_comment
      ProcessedAiRun.claim_canonical("r-folded", comment)
      assert_equal comment.id, ProcessedAiRun.comment_for("r-folded")&.id

      comment.destroy

      assert ProcessedAiRun.processed?("r-folded"), "run row survives via ON DELETE SET NULL"
      assert_nil ProcessedAiRun.comment_for("r-folded"), "comment reference is nullified"
    end

    test "claim_canonical reclaims the run from a proactive duplicate and removes it" do
      duplicate = make_comment("proactive duplicate")
      ProcessedAiRun.claim_proactive("r-race", duplicate)
      canonical = make_comment("canonical solicited reply")

      ProcessedAiRun.claim_canonical("r-race", canonical)

      assert_equal canonical.id, ProcessedAiRun.comment_for("r-race")&.id, "canonical owns the run"
      assert_not Collavre::Comment.exists?(duplicate.id), "proactive duplicate is removed"
      assert_equal 1, ProcessedAiRun.where(run_id: "r-race").count
    end

    private

    def make_comment(content = "c")
      @creative.comments.create!(user: @user, content: content)
    end
  end
end
