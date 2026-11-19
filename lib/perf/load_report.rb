# frozen_string_literal: true

require "json"

module Perf
  # Turns the raw samples of a multi-user agent load run into metrics and
  # pass/fail checks against the capacity target. Pure Ruby on plain data, so the
  # verdict logic is unit-tested without a server.
  #
  # Inputs (times are monotonic seconds):
  #   posts:    [{ tag:, posted_at:, latency:, ok: }]  one per user message
  #   llm:      [{ tag:, started_at:, finished_at: }]  provider requests seen
  #   probes:   [{ latency:, ok: }]                     UI reads during the load
  #   outcomes: { "done" => 38, "failed" => 2, ... }    task status counts
  class LoadReport
    DEFAULT_SLO = {
      start_p95: 5.0,
      web_p95: 1.0,
      post_p95: 2.0
    }.freeze

    Check = Struct.new(:name, :actual, :target, :passed, keyword_init: true)

    def self.percentile(values, pct)
      sorted = values.compact.sort
      return nil if sorted.empty?

      sorted[((pct / 100.0) * (sorted.size - 1)).round]
    end

    def initialize(expected_turns:, posts:, llm:, probes:, outcomes:, peak_llm:, slo: {}, meta: {})
      @expected_turns = expected_turns
      @posts = posts
      @llm = llm
      @probes = probes
      @outcomes = outcomes
      @peak_llm = peak_llm
      @slo = DEFAULT_SLO.merge(slo)
      @meta = meta
    end

    def metrics
      @metrics ||= {
        expected_turns: @expected_turns,
        completed_turns: @outcomes.fetch("done", 0),
        task_statuses: @outcomes,
        peak_concurrent_llm: @peak_llm,
        unstarted_turns: unstarted_tags.size,
        start_latency: summary(start_latencies),
        post_latency: summary(@posts.map { |post| post[:latency] }),
        post_errors: @posts.count { |post| !post[:ok] },
        web_latency: summary(@probes.map { |probe| probe[:latency] }),
        web_errors: @probes.count { |probe| !probe[:ok] },
        error_kinds: (@posts + @probes).reject { |sample| sample[:ok] }.map { |sample| error_kind(sample) }.tally
      }
    end

    def checks
      m = metrics
      [
        check("all turns completed", m[:completed_turns], ">= #{@expected_turns}", m[:completed_turns] >= @expected_turns),
        check("all turns streamed at once", m[:peak_concurrent_llm], ">= #{@expected_turns}",
              m[:peak_concurrent_llm] >= @expected_turns),
        max_check("agent start p95 (s)", m.dig(:start_latency, :p95), @slo[:start_p95]),
        max_check("comment post p95 (s)", m.dig(:post_latency, :p95), @slo[:post_p95]),
        max_check("UI read p95 (s)", m.dig(:web_latency, :p95), @slo[:web_p95]),
        check("request errors", m[:post_errors] + m[:web_errors], "== 0", (m[:post_errors] + m[:web_errors]).zero?)
      ]
    end

    def passed?
      checks.all?(&:passed)
    end

    def to_h
      { meta: @meta, slo: @slo, metrics: metrics, checks: checks.map(&:to_h), passed: passed? }
    end

    def to_text
      lines = [ "Multi-user agent load: #{passed? ? 'PASS' : 'FAIL'}" ]
      @meta.each { |key, value| lines << "  #{key}: #{value}" }
      lines << "  task statuses: #{@outcomes}"
      lines << "  start latency: #{format_summary(metrics[:start_latency])}"
      lines << "  post latency:  #{format_summary(metrics[:post_latency])}"
      lines << "  UI latency:    #{format_summary(metrics[:web_latency])}"
      lines << "  errors:        #{metrics[:error_kinds]}" if metrics[:error_kinds].any?
      checks.each do |item|
        lines << format("  [%s] %-28s actual=%-8s target %s", item.passed ? "PASS" : "FAIL", item.name,
                        item.actual.nil? ? "n/a" : item.actual, item.target)
      end
      lines.join("\n")
    end

    private

    def first_llm_start_by_tag
      @first_llm_start_by_tag ||= @llm.each_with_object({}) do |request, starts|
        next unless request[:tag]

        starts[request[:tag]] = [ starts[request[:tag]], request[:started_at] ].compact.min
      end
    end

    def start_latencies
      @posts.filter_map do |post|
        started = first_llm_start_by_tag[post[:tag]]
        started && (started - post[:posted_at])
      end
    end

    def unstarted_tags
      @posts.map { |post| post[:tag] } - first_llm_start_by_tag.keys
    end

    def summary(values)
      values = values.compact
      return { count: 0 } if values.empty?

      { count: values.size, p50: round(self.class.percentile(values, 50)),
        p95: round(self.class.percentile(values, 95)), max: round(values.max) }
    end

    def format_summary(summary)
      return "no samples" if summary[:count].zero?

      "n=#{summary[:count]} p50=#{summary[:p50]}s p95=#{summary[:p95]}s max=#{summary[:max]}s"
    end

    def error_kind(sample)
      sample[:error] || "HTTP #{sample[:status]}"
    end

    def round(value)
      value&.round(3)
    end

    def check(name, actual, target, passed)
      Check.new(name: name, actual: actual, target: target, passed: passed)
    end

    # A missing sample means the thing never happened, which fails the target.
    def max_check(name, actual, limit)
      check(name, actual, "<= #{limit}", !actual.nil? && actual <= limit)
    end
  end
end
