# frozen_string_literal: true

# Multi-user agent capacity test. Run with `bin/rails runner` in the same
# environment and database as the server under test:
#
#   PERF_BASE_URL=http://127.0.0.1:3000 bin/rails runner script/perf/multi_user_agents.rb
#
# script/perf/run_local.sh boots a production-like server (desktop env:
# Solid Queue in Puma, Solid Cache) and runs this against it. Knobs:
#   PERF_USERS (10)  PERF_AGENTS (4)  PERF_LLM_SECONDS (20)  PERF_TIMEOUT (300)
#   PERF_START_P95 / PERF_POST_P95 / PERF_WEB_P95 (seconds)  PERF_REPORT (JSON path)
# Exits 1 when any capacity check fails.

require Rails.root.join("lib/perf/multi_user_agent_load").to_s

env = ENV
slo = { start_p95: env["PERF_START_P95"], post_p95: env["PERF_POST_P95"], web_p95: env["PERF_WEB_P95"] }
      .compact.transform_values(&:to_f)

report = Perf::MultiUserAgentLoad.new(
  base_url: env.fetch("PERF_BASE_URL", "http://127.0.0.1:3000"),
  users: env.fetch("PERF_USERS", 10).to_i,
  agents: env.fetch("PERF_AGENTS", 4).to_i,
  llm_seconds: env.fetch("PERF_LLM_SECONDS", 20).to_f,
  timeout: env.fetch("PERF_TIMEOUT", 300).to_f,
  slo: slo
).run

puts report.to_text
path = env.fetch("PERF_REPORT", Rails.root.join("tmp/perf/multi_user_agents-#{Time.now.strftime('%Y%m%d%H%M%S')}.json").to_s)
FileUtils.mkdir_p(File.dirname(path))
File.write(path, JSON.pretty_generate(report.to_h))
puts "report: #{path}"
exit(report.passed? ? 0 : 1)
