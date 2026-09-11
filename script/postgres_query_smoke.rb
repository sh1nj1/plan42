# frozen_string_literal: true

# Executes request-path queries against a real PostgreSQL, from CI's
# `postgres_schema_load` job.
#
# Dev and test run SQLite, production runs PostgreSQL, and the two disagree
# about more than schema DDL. `SELECT DISTINCT users.*` is the standing example:
# SQLite compares the table's `json` columns happily, PostgreSQL has no equality
# operator for `json` and raises
# `PG::UndefinedFunction: could not identify an equality operator for type json`.
# A fully green SQLite suite says nothing about that, so the queries that MCP
# callers reach are run here for real.
#
# Usage: RAILS_ENV=test DATABASE_URL=postgresql://... bin/rails runner script/postgres_query_smoke.rb

abort "postgres_query_smoke expects a PostgreSQL connection" unless
  ActiveRecord::Base.connection.adapter_name.match?(/postg/i)

failures = []

def check(failures, label)
  yield
  puts "ok   #{label}"
rescue StandardError => e
  failures << "#{label}: #{e.class}: #{e.message.lines.first.to_s.strip}"
  puts "FAIL #{label}"
end

suffix = SecureRandom.hex(4)
actor = Collavre::User.create!(
  name: "Smoke Owner", email: "smoke-owner-#{suffix}@example.test", password: "password123"
)
Collavre::Current.user = actor
creative = Collavre::Creative.create!(description: "Smoke Host", user: actor)
Collavre::User.create!(
  name: "Smoke Reviewer", email: "smoke-agent-#{suffix}@example.test", password: "password123",
  llm_vendor: "google", llm_model: "gemini-1.5-flash", searchable: true
)

# Reached by the completion API's model list.
check(failures, "User.accessible_ai_agents_for") do
  Collavre::User.accessible_ai_agents_for(actor).to_a
end

# Reached by topic_create / topic_update with primary_agent, both with and
# without a creative to scope the candidates.
check(failures, "AgentResolver.candidates_for(no creative)") do
  Collavre::Topics::AgentResolver.candidates_for(actor, nil).to_a
end

check(failures, "AgentResolver.candidates_for(creative)") do
  Collavre::Topics::AgentResolver.candidates_for(actor, creative).to_a
end

check(failures, "AgentResolver.call(name, creative:)") do
  Collavre::Topics::AgentResolver.call("Smoke Reviewer", actor: actor, creative: creative) ||
    raise("expected the searchable agent to resolve")
end

# Reached by each queued gateway health probe. Agent gateways carry a json
# health_engines column, so this relation must not select whole rows with
# DISTINCT either.
check(failures, "AgentGateway.health_probe_targets") do
  Collavre::AgentGateway.health_probe_targets.find_by(id: -1)
end

abort "\n#{failures.size} PostgreSQL-incompatible query/queries:\n- #{failures.join("\n- ")}" if failures.any?
puts "\nAll guarded queries execute on PostgreSQL."
