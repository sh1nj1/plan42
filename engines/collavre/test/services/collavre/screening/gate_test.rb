# frozen_string_literal: true

require "test_helper"
require_relative "screening_test_support"

module Collavre
  module Screening
    class GateTest < ActiveSupport::TestCase
      include ScreeningTestSupport

      setup do
        @agent = users(:ai_bot)
        @task = Task.create!(name: "Screen", agent: @agent, status: "running")
        @texts = [ { source: "trigger", text: "please summarize" } ]
      end

      def gate(texts = @texts) = Gate.new.call(texts, agent: @agent, creative: nil, task: @task)

      test "probability maps to passed, flagged and blocked using the thresholds" do
        { 0.1 => "passed", 0.5 => "flagged", 0.95 => "blocked" }.each do |probability, expected|
          with_screeners([ fake_screener(probability) ]) { assert_equal expected, gate.verdict }
        end
        SystemSetting.create!(key: "screening_threshold", value: "0.2")
        SystemSetting.create!(key: "screening_block_threshold", value: "0.4")
        with_screeners([ fake_screener(0.3) ]) { assert_equal "flagged", gate.verdict }
      end

      test "a failing screener is an error, never a pass" do
        screener = fake_screener(RuntimeError.new("boom"))
        with_screeners([ screener ]) do
          verdict = gate
          assert_equal "error", verdict.verdict
          assert_equal "RuntimeError", verdict.error
        end
        with_screeners([ fake_screener("not a number") ]) { assert_equal "error", gate.verdict }
      end

      test "the strictest screener wins and a block outranks an error" do
        with_screeners([ fake_screener(0.1), fake_screener(0.6, id: "agent:1") ]) { assert_equal "flagged", gate.verdict }
        with_screeners([ fake_screener(RuntimeError.new("x")), fake_screener(0.1, id: "agent:1") ]) { assert_equal "error", gate.verdict }
        with_screeners([ fake_screener(RuntimeError.new("x")), fake_screener(0.99, id: "agent:1") ]) { assert_equal "blocked", gate.verdict }
      end

      test "every chunk is judged and the worst chunk decides" do
        screener = fake_screener([ 0.1, 0.97 ])
        texts = [ { source: "doc", text: "x" * (Input::MAX_CHARS + 1) } ]
        with_screeners([ screener ]) { assert_equal "blocked", gate(texts).verdict }
        assert_equal 2, screener.calls.size
      end

      test "each screener's verdict is audited on the task" do
        with_screeners([ fake_screener(0.2), fake_screener(0.7, id: "agent:9") ]) { gate }
        payloads = @task.task_actions.where(action_type: ACTION_TYPE).order(:id).map(&:payload)
        assert_equal [ "system", "agent:9" ], payloads.map { |p| p["screener_id"] }
        assert_equal [ "passed", "flagged" ], payloads.map { |p| p["verdict"] }
        assert_equal [ POLICY_VERSION ], payloads.map { |p| p["policy_version"] }.uniq
        assert_equal [ Screening.digest(@texts) ], payloads.map { |p| p["content_digest"] }.uniq
        assert_equal "jev-latest", payloads.first["model"]
      end

      test "screening marks the current execution while it runs" do
        seen = nil
        screener = fake_screener(0.1)
        screener.define_singleton_method(:judge) { |_input| seen = Current.screening; { "answers" => { "injection" => { "probability" => 0.1 } } } }
        with_screeners([ screener ]) { gate }
        assert seen
        assert_nil Current.screening
      end

      test "empty content passes without a judge call" do
        screener = fake_screener(0.99)
        with_screeners([ screener ]) { assert_equal "passed", gate([ { source: "trigger", text: "" } ]).verdict }
        assert_empty screener.calls
      end
    end
  end
end
