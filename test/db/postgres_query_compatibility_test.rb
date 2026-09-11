# frozen_string_literal: true

require "test_helper"

# Dev and test run SQLite; the deployed environment runs PostgreSQL. SQLite will
# compare `json` values, PostgreSQL has no equality operator for the `json` type
# at all, so `SELECT DISTINCT users.*` is accepted here and raises
# `PG::UndefinedFunction: could not identify an equality operator for type json`
# there. The CI `postgres_schema_load` job covers SQLite-only *schema*
# constructs; this covers SQLite-only *queries*, which no amount of green local
# test runs would surface.
#
# Guarded relations are the ones that load whole AI-agent rows on request paths
# an MCP caller reaches (`topic_create` / `topic_update` with `primary_agent`,
# and the completion API's model list).
class PostgresQueryCompatibilityTest < ActiveSupport::TestCase
  DISTINCT = /SELECT\s+DISTINCT/i

  setup do
    @user = users(:one)
    @creative = Collavre::Creative.create!(description: "Agent Host", user: @user)
  end

  # Pins the premise. If `users` ever loses its `json` columns the assertions
  # below stop meaning anything, and this test says so out loud instead.
  test "the users table carries json columns" do
    json_columns = Collavre::User.columns.select { |c| c.sql_type.to_s.downcase == "json" }.map(&:name)

    assert_includes json_columns, "tools"
    assert_includes json_columns, "dismissed_notices"
  end

  test "accessible_ai_agents_for selects whole rows without DISTINCT" do
    sql = Collavre::User.accessible_ai_agents_for(@user).to_sql

    refute_match DISTINCT, sql,
      "DISTINCT over users.* raises PG::UndefinedFunction on PostgreSQL because users has json columns"
  end

  test "the agent resolver candidate scope selects whole rows without DISTINCT" do
    [ nil, @creative ].each do |creative|
      sql = Collavre::Topics::AgentResolver.candidates_for(@user, creative).to_sql

      refute_match DISTINCT, sql,
        "DISTINCT over users.* raises PG::UndefinedFunction on PostgreSQL (creative: #{creative.inspect})"
    end
  end
end
