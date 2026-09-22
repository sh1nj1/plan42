# frozen_string_literal: true

require "test_helper"
require "ostruct"

class LlmUsageTest < ActiveSupport::TestCase
  setup do
    @owner = users(:two)
    @requester = users(:three)
    @agent = Collavre::User.create!(email: "usage-agent@example.com", name: "Usage Agent", password: TEST_PASSWORD,
      llm_vendor: "openai", llm_model: "test-model", system_prompt: "Help", created_by_id: @owner.id)
    @creative = Collavre::Creative.create!(description: "Usage", user: @owner)
    @comment = @creative.comments.create!(user: @requester, content: "Please help", skip_dispatch: true)
    @task = Collavre::Task.create!(name: "Usage test", agent: @agent, creative: @creative,
      topic_id: @comment.topic_id, trigger_event_payload: { "comment" => { "id" => @comment.id } })
  end

  def recorder(**options)
    Collavre::LlmUsage::Recorder.new(context: { task: @task, user: @agent }, vendor: "openai", model: "test", **options)
  end

  def response(**options)
    RubyLLM::Message.new({ role: :assistant, content: "done", input_tokens: 10, output_tokens: 4,
      cached_tokens: 50, cache_creation_tokens: 20 }.merge(options))
  end

  test "records inclusive input without double counting and links activity log" do
    collector = recorder
    message = response(raw: { "usage" => { "prompt_tokens" => 80 }, "secret" => "not stored" })
    collector.observe(message)
    collector.record(message)
    collector.record(message)
    collector.finish(message)
    row = Collavre::LlmUsage.last
    assert_equal 1, Collavre::LlmUsage.where(execution_id: collector.execution_id).count
    assert_equal [ 80, 4, 50, 20 ], row.attributes.values_at(*Collavre::LlmUsage::TOKEN_FIELDS.map(&:to_s))
    assert_equal @requester.id, row.requester_id
    assert_equal @owner.id, row.owner_id
    assert_equal @task.id, row.task_id
    assert_equal @comment.topic_id, row.topic_id
    assert_equal({ "prompt_tokens" => 80 }, row.raw_usage["provider"])
    refute_includes row.raw_usage.to_json, "not stored"
    log = Collavre::ActivityLog.create!(activity: "llm_query")
    collector.attach(nil)
    collector.attach(log)
    assert_equal log.id, row.reload.activity_log_id
  end

  test "captures every assistant call but excludes tool results and counts retries separately" do
    collector = recorder
    collector.record(response)
    collector.record(RubyLLM::Message.new(role: :tool, content: "tool result"))
    collector.record(response)
    collector.finish
    recorder.finish(response)
    assert_equal 3, Collavre::LlmUsage.count
    assert_equal 2, Collavre::LlmUsage.distinct.count(:execution_id)
  end

  test "interrupted streams preserve reported usage and missing values stay nil" do
    collector = recorder
    collector.observe(OpenStruct.new(input_tokens: 12, cached_tokens: 0))
    collector.observe(OpenStruct.new(output_tokens: 3))
    collector.finish
    row = Collavre::LlmUsage.last
    assert_equal 12, row.input_tokens
    assert_equal 3, row.output_tokens
    assert_equal 0, row.cache_read_tokens
    assert_nil row.cache_write_tokens
    collector.finish
    assert_equal 1, Collavre::LlmUsage.count
  end

  test "failure without reported usage records unknown not zero" do
    recorder.finish
    assert_equal [ nil, nil, nil, nil ], Collavre::LlmUsage.last.attributes.values_at(*Collavre::LlmUsage::TOKEN_FIELDS.map(&:to_s))
  end

  test "owner snapshot survives transfer and requester survives trigger replacement after starting" do
    recorder.finish(response)
    @agent.update!(created_by_id: @requester.id)
    @task.update!(status: "running")
    another = @creative.comments.create!(user: @owner, content: "Other request", skip_dispatch: true)
    @task.update!(trigger_event_payload: { "comment" => { "id" => another.id } })
    recorder.finish(response)
    assert_equal [ @owner.id ], Collavre::LlmUsage.distinct.pluck(:owner_id)
    assert_equal [ @requester.id ], Collavre::LlmUsage.distinct.pluck(:requester_id)
  end

  test "agent handoffs inherit human requester and do not substitute agent owner" do
    reply = @creative.comments.create!(user: @agent, task: @task, content: "Delegated", skip_dispatch: true)
    child = Collavre::Task.create!(name: "Delegation", agent: @agent,
      trigger_event_payload: { "comment" => { "id" => reply.id } })
    assert_equal [ @requester.id ], child.usage_attribution["requester_ids"]
    assert_includes child.usage_attribution["source_comment_ids"], @comment.id
    orphan = @creative.comments.create!(user: @agent, content: "External event", skip_dispatch: true)
    child = Collavre::Task.create!(name: "Unknown", agent: @agent,
      trigger_event_payload: { "comment" => { "id" => orphan.id } })
    assert_empty child.usage_attribution["requester_ids"]
  end

  test "merged and reanchored pending tasks preserve all requesters as joint" do
    other = @creative.comments.create!(user: @owner, content: "Other request", skip_dispatch: true)
    @task.update!(trigger_event_payload: { "comment" => { "id" => other.id }, "merged_comment_ids" => [ @comment.id ] })
    recorder.finish(response)
    row = Collavre::LlmUsage.last
    assert_equal "joint", row.requester_kind
    assert_nil row.requester_id
    assert_equal [ @owner.id, @requester.id ].sort, row.requester_ids
    assert_equal 1, Collavre::LlmUsage.visible_to(@requester).count
  end

  test "standalone calls use only an evidenced human and tolerate absent context" do
    attributes = Collavre::LlmUsage::Attribution.snapshot(comment: @comment, user: @agent, creative: @creative)
    assert_equal @requester.id, attributes[:requester_id]
    assert_equal @owner.id, attributes[:owner_id]
    assert_equal "unknown", Collavre::LlmUsage::Attribution.snapshot({})[:requester_kind]
  end

  test "standalone explicit requester can see usage for another owners agent" do
    collector = Collavre::LlmUsage::Recorder.new(
      context: { user: @agent, requester: @requester, creative: @creative, topic_id: @comment.topic_id },
      vendor: "openai", model: "test")
    collector.finish(response)
    row = Collavre::LlmUsage.last
    assert_equal @requester.id, row.requester_id
    assert_equal @owner.id, row.owner_id
    assert_equal @comment.topic_id, row.topic_id
    assert_equal [ row.id ], Collavre::LlmUsage.visible_to(@requester).pluck(:id)
    assert_equal "unknown", Collavre::LlmUsage::Attribution.snapshot(requester: @agent)[:requester_kind]
  end

  test "run measurements and database idempotency are explicit" do
    recorder(measurement: "run").finish(response)
    original = Collavre::LlmUsage.last
    assert_equal "run", original.measurement
    assert_raises(ActiveRecord::RecordNotUnique) { original.dup.save! }
    original.input_tokens = -1
    refute original.valid?
  end

  test "raw usage extracts JSON and streaming metadata without retaining payload" do
    normalizer = Collavre::LlmUsage::TokenNormalizer
    raw = "data: {\"message\":{\"usage\":{\"input_tokens\":5}}}\n" \
      "data: {\"usage\":{\"output_tokens\":3}}\n" \
      "data: [DONE]\n"
    assert_equal({ "input_tokens" => 5, "output_tokens" => 3 }, normalizer.raw_usage(OpenStruct.new(raw: OpenStruct.new(body: raw))))
    assert_equal({ "cachedContentTokenCount" => 5 }, normalizer.raw_usage(OpenStruct.new(raw: '{"usageMetadata":{"cachedContentTokenCount":5}}')))
    assert_equal({}, normalizer.raw_usage(OpenStruct.new(raw: "{bad")))
    assert_equal({}, normalizer.raw_usage(nil))
    assert_equal({}, normalizer.raw_usage(OpenStruct.new(raw: { "usage" => 0 })))
    assert_nil normalizer.parts(OpenStruct.new(input_tokens: -1))[:input_tokens]
    assert_nil normalizer.parts(OpenStruct.new(input_tokens: "4"))[:input_tokens]
  end

  test "KST day week and month boundaries respect visibility and missing counts" do
    travel_to Time.utc(2026, 9, 1) do
      collector = recorder
      collector.finish(response)
      row = Collavre::LlmUsage.last
      row.update!(occurred_at: Time.utc(2026, 8, 31, 14, 59, 59))
      recorder.finish
      Collavre::LlmUsage.last.update!(occurred_at: Time.utc(2026, 8, 31, 15))
      %w[day week month].each do |period|
        result = report(period: period, from: "2026-08-01", to: "2026-08-31").rows
        assert_equal 1, result.size
        assert_equal(period == "month" ? "2026-08-01" : "2026-08-31", result.first[:period])
        assert_equal 80, result.first[:input_tokens]
      end
      result = report(from: "2026-09-01", to: "2026-09-01").rows.first
      assert_nil result[:input_tokens]
      assert_equal 1, result[:input_tokens_missing]
      assert_equal 1, report(group: "model", model: "test").rows.size
      assert_empty report(model: "no-match").rows
    end
  end

  test "scope cannot be expanded by foreign identity filters" do
    recorder.finish(response)
    outsider = Collavre::User.create!(email: "outsider-usage@example.com", name: "Outsider", password: TEST_PASSWORD)
    assert_empty Collavre::LlmUsage.visible_to(nil)
    assert_empty Collavre::LlmUsage.visible_to(outsider)
    assert_empty report(user: outsider, owner_id: @owner.id).rows
    assert_equal 1, report(user: @requester, requester_id: @requester.id).rows.size
    @owner.stub(:system_admin?, true) { assert_equal 1, Collavre::LlmUsage.visible_to(@owner).count }
  end

  test "joint usage appears once and unknown attribution remains a separate group" do
    other = @creative.comments.create!(user: @owner, content: "Other", skip_dispatch: true)
    @task.update!(trigger_event_payload: { "comment" => { "id" => other.id }, "merged_comment_ids" => [ @comment.id ] })
    recorder.finish(response)
    @task.update!(usage_attribution: { "owner_id" => @owner.id })
    recorder.finish(response)
    result = report(group: "requester").rows
    assert_equal 2, result.size
    assert_equal [ nil, "joint" ], result.map { |row| row[:group] }
    assert_equal 160, result.sum { |row| row[:input_tokens] }
  end

  test "invalid dates periods and dimensions are rejected" do
    [ { period: "year" }, { group: "password" }, { from: "invalid" },
     { from: "2026-09-01", to: "2026-08-01" }, { from: "2020-01-01", to: "2026-01-01" } ].each do |params|
      assert_raises(ArgumentError) { report(**params) }
    end
  end

  test "a mixed known and unknown request stays joint instead of charging one person" do
    orphan = @creative.comments.create!(user: @agent, content: "External", skip_dispatch: true)
    @task.update!(trigger_event_payload: { "comment" => { "id" => @comment.id }, "merged_comment_ids" => [ orphan.id ] })
    recorder.finish(response)
    row = Collavre::LlmUsage.last
    assert_equal "joint", row.requester_kind
    assert_nil row.requester_id
    assert_equal [ @requester.id ], row.requester_ids
  end

  test "tool and scheduled dispatch provenance comes from the initiating task" do
    Collavre::Current.set(user: @agent, agent_turn: { task: @task, user: @owner }) do
      carried = Collavre::LlmUsage::Attribution.current_requesters
      assert_equal [ @requester.id ], carried["requester_ids"]
      payload = { "comment" => { "id" => nil }, "usage_requester_attribution" => carried }
      child = Collavre::Task.create!(name: "Scheduled delegation", agent: @agent, trigger_event_payload: payload)
      assert_equal [ @requester.id ], child.usage_attribution["requester_ids"]
      assert_equal "human", Collavre::LlmUsage::Attribution.attributes(child.usage_attribution)[:requester_kind]
    end
    Collavre::Current.set(user: @requester) do
      assert_equal [ @requester.id ], Collavre::LlmUsage::Attribution.current_requesters["requester_ids"]
    end
    Collavre::Current.set(user: @agent) do
      assert_empty Collavre::LlmUsage::Attribution.current_requesters["requester_ids"]
    end
  end

  test "a Sunday belongs to the preceding Monday and boundaries are exclusive" do
    recorder.finish(response)
    row = Collavre::LlmUsage.last
    row.update!(occurred_at: Time.utc(2026, 8, 30, 14, 59, 59))
    assert_equal "2026-08-24", report(period: "week", from: "2026-08-30", to: "2026-08-30").rows.first[:period]
    row.update!(occurred_at: Time.utc(2026, 8, 30, 15))
    assert_empty report(from: "2026-08-30", to: "2026-08-30").rows
    assert_equal "2026-08-31", report(period: "week", from: "2026-08-31", to: "2026-08-31").rows.first[:period]
  end

  private

  def report(user: @owner, **params)
    Collavre::LlmUsage::Report.new(user: user, params: params)
  end
end
