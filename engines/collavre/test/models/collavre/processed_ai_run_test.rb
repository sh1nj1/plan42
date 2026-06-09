# frozen_string_literal: true

require "test_helper"

module Collavre
  class ProcessedAiRunTest < ActiveSupport::TestCase
    test "record stores a run and processed? reports it" do
      assert_not ProcessedAiRun.processed?("run-x")

      assert ProcessedAiRun.record("run-x")
      assert ProcessedAiRun.processed?("run-x")
    end

    test "record is idempotent for the same run_id" do
      assert ProcessedAiRun.record("run-dup")
      assert ProcessedAiRun.record("run-dup"), "second record is a no-op, not an error"

      assert_equal 1, ProcessedAiRun.where(run_id: "run-dup").count
    end

    test "record and processed? are no-ops for a blank run_id" do
      assert_not ProcessedAiRun.record(nil)
      assert_not ProcessedAiRun.record("")
      assert_not ProcessedAiRun.processed?(nil)
    end
  end
end
