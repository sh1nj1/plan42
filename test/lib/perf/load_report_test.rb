# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/perf/load_report").to_s

module Perf
  class LoadReportTest < ActiveSupport::TestCase
    def post(tag, posted_at, latency: 0.2, ok: true, status: 201)
      { tag: tag, posted_at: posted_at, latency: latency, ok: ok, status: status }
    end

    def llm(tag, started_at)
      { tag: tag, started_at: started_at, finished_at: started_at + 20 }
    end

    def report(**overrides)
      LoadReport.new(**{
        expected_turns: 2,
        posts: [ post("a", 0.0), post("b", 0.0) ],
        llm: [ llm("a", 1.0), llm("b", 2.0) ],
        probes: [ { latency: 0.05, ok: true, status: 200 } ],
        outcomes: { "done" => 2 },
        peak_llm: 2
      }.merge(overrides))
    end

    test "percentile picks the nearest rank and ignores nils" do
      assert_equal 3, LoadReport.percentile([ 5, 1, nil, 3 ], 50)
      assert_equal 5, LoadReport.percentile([ 5, 1, 3 ], 95)
      assert_nil LoadReport.percentile([ nil ], 50)
    end

    test "passes when every turn ran at once within the latency targets" do
      result = report

      assert result.passed?
      assert_equal 2.0, result.metrics.dig(:start_latency, :max)
      assert_equal({}, result.metrics[:error_kinds])
      assert_match "Multi-user agent load: PASS", result.to_text
    end

    test "fails capacity when fewer turns streamed concurrently than expected" do
      result = report(peak_llm: 1)

      assert_not result.passed?
      failed = result.checks.reject(&:passed).map(&:name)
      assert_equal [ "all turns streamed at once" ], failed
    end

    test "uses the first provider request per message for start latency" do
      result = report(llm: [ llm("a", 4.0), llm("a", 1.0), llm("b", 1.0), llm(nil, 0.5) ])

      assert_equal 1.0, result.metrics.dig(:start_latency, :max)
    end

    test "a message the provider never saw fails the start target" do
      result = report(llm: [], peak_llm: 0, outcomes: { "missing" => 2 })

      assert_equal 2, result.metrics[:unstarted_turns]
      assert_equal({ count: 0 }, result.metrics[:start_latency])
      start = result.checks.find { |item| item.name == "agent start p95 (s)" }
      assert_not start.passed
      assert_match "start latency: no samples", result.to_text
      assert_match "actual=n/a", result.to_text
    end

    test "counts failed requests by kind" do
      result = report(
        posts: [ post("a", 0.0), post("b", 0.0, latency: nil, ok: false, status: nil).merge(error: "Errno::ECONNRESET") ],
        probes: [ { latency: 0.1, ok: false, status: 500 } ]
      )

      assert_equal({ "Errno::ECONNRESET" => 1, "HTTP 500" => 1 }, result.metrics[:error_kinds])
      assert_not result.checks.find { |item| item.name == "request errors" }.passed
      assert_match "errors:", result.to_text
    end

    test "honours custom latency targets and serializes the verdict" do
      result = report(slo: { start_p95: 0.5 }, meta: { users: 1 })

      assert_not result.passed?
      hash = result.to_h
      assert_equal 0.5, hash[:slo][:start_p95]
      assert_equal({ users: 1 }, hash[:meta])
      assert_equal false, hash[:passed]
      assert_match "users: 1", result.to_text
    end
  end
end
