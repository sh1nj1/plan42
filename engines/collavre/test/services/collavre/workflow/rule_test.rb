# frozen_string_literal: true

require "test_helper"

module Collavre
  module Workflow
    class RuleTest < ActiveSupport::TestCase
      test "parses a workflow rule into an immutable value" do
        creative = creative_with({
          "on" => "comment_created",
          "when" => { "source" => [ "cron" ], "author_agent" => true },
          "handler" => { "type" => "agent", "agent_ids" => [ 17, 23 ] },
          "emits" => [ "comment_created" ]
        })

        rule, errors = Rule.parse(creative)

        assert_empty errors
        assert_equal Rule.new(
          creative_id: 42,
          event_name: "comment_created",
          conditions: { "source" => [ "cron" ], "author_agent" => true },
          handler_type: "agent",
          agent_ids: [ 17, 23 ],
          emits: [ "comment_created" ]
        ), rule
        assert rule.responder?
        assert rule.event_name.frozen?
        assert rule.conditions.frozen?
        assert rule.conditions["source"].frozen?
        assert rule.handler_type.frozen?
        assert rule.agent_ids.frozen?
        assert rule.emits.frozen?
      end

      test "returns nil without errors for a creative that is not a rule" do
        rule, errors = Rule.parse(creative_with({}, kind: "note"))

        assert_nil rule
        assert_empty errors
      end

      test "missing event is fatal" do
        rule, errors = Rule.parse(creative_with("handler" => { "type" => "human" }))

        assert_nil rule
        assert_equal [ I18n.t("collavre.workflow.rule.errors.missing_on") ], errors
      end

      test "unknown event is fatal" do
        rule, errors = Rule.parse(creative_with(
          "on" => "future_event", "handler" => { "type" => "human" }
        ))

        assert_nil rule
        assert_equal [ I18n.t("collavre.workflow.rule.errors.unknown_event", event: "future_event") ], errors
      end

      test "missing or unsupported handler is fatal" do
        [ nil, {}, { "type" => "robot" } ].each do |handler|
          rule, errors = Rule.parse(creative_with("on" => "comment_created", "handler" => handler))

          assert_nil rule
          assert_equal [ I18n.t("collavre.workflow.rule.errors.unknown_handler") ], errors
        end
      end

      test "agent handler requires a nonempty integer ID list" do
        [ nil, [], [ "17" ], [ 17, nil ] ].each do |agent_ids|
          rule, errors = Rule.parse(creative_with(
            "on" => "comment_created",
            "handler" => { "type" => "agent", "agent_ids" => agent_ids }
          ))

          assert_nil rule
          assert_equal [ I18n.t("collavre.workflow.rule.errors.no_agent") ], errors
        end
      end

      test "valid agent IDs do not require an existing user" do
        finder = ->(*) { flunk "Rule parsing must not query users" }

        User.stub(:where, finder) do
          rule, errors = Rule.parse(creative_with(
            "on" => "comment_created",
            "handler" => { "type" => "agent", "agent_ids" => [ 999_999 ] }
          ))

          assert_empty errors
          assert_equal [ 999_999 ], rule.agent_ids
        end
      end

      test "unknown emitted events are advisory" do
        rule, errors = Rule.parse(creative_with(
          "on" => "comment_created",
          "handler" => { "type" => "none" },
          "emits" => [ "future_event" ]
        ))

        assert_equal [ "future_event" ], rule.emits
        assert_equal [ I18n.t("collavre.workflow.rule.errors.unknown_emit", event: "future_event") ], errors
      end

      test "unknown conditions are advisory and ignored without mutating source data" do
        creative = creative_with({
          "on" => "comment_created",
          "when" => { "source" => [ "cron" ], "future_predicate" => { "x" => 1 } },
          "handler" => { "type" => "human" }
        })
        original_data = Marshal.load(Marshal.dump(creative.data))

        rule, errors = Rule.parse(creative)

        assert_equal({ "source" => [ "cron" ] }, rule.conditions)
        assert_equal [
          I18n.t("collavre.workflow.rule.errors.unknown_condition", condition: "future_predicate")
        ], errors
        assert_equal original_data, creative.data
      end

      test "malformed containers and known predicate values are fatal without raising" do
        invalid_payloads = [
          nil,
          [],
          { "on" => "comment_created", "handler" => [], "when" => {} },
          { "on" => "comment_created", "handler" => { "type" => "human" }, "when" => [] },
          { "on" => "comment_created", "handler" => { "type" => "human" }, "emits" => "event" },
          rule_payload("when" => { "source" => "cron" }),
          rule_payload("when" => { "author_agent" => "yes" }),
          rule_payload("when" => { "body_contains" => [ 3 ] }),
          rule_payload("when" => { "liquid" => false })
        ]
        creatives = [ OpenStruct.new(id: 42, data: nil), OpenStruct.new(id: 42, data: []) ]
        creatives.concat(invalid_payloads.map { |payload| raw_creative(payload) })

        creatives.each do |creative|
          rule, errors = Rule.parse(creative)

          assert_nil rule
          assert_not_empty errors
        end
      end

      test "from logs parser errors and never raises for malformed data" do
        warnings = []

        Rails.logger.stub(:warn, ->(message) { warnings << message }) do
          assert_nil Rule.from(OpenStruct.new(id: 42, data: "bad"))
        end

        assert_equal 1, warnings.size
        assert_match(/42/, warnings.first)
      end

      test "parse absorbs unexpected malformed accessors" do
        creative = Object.new
        creative.define_singleton_method(:data) { raise TypeError, "malformed JSON" }

        rule, errors = Rule.parse(creative)

        assert_nil rule
        assert_equal [ I18n.t("collavre.workflow.rule.errors.invalid_structure") ], errors
      end

      test "human and none handlers are not responders" do
        %w[human none].each do |type|
          rule = Rule.from(creative_with(
            "on" => "comment_created", "handler" => { "type" => type }
          ))

          refute rule.responder?
        end
      end

      test "localized errors are available in English and Korean" do
        %i[en ko].each do |locale|
          I18n.with_locale(locale) do
            _rule, errors = Rule.parse(creative_with("handler" => { "type" => "human" }))

            assert_equal I18n.t("collavre.workflow.rule.errors.missing_on"), errors.first
            refute_match(/translation missing/i, errors.first)
          end
        end
      end

      private

      def creative_with(payload = nil, kind: "workflow_rule", **fields)
        payload ||= fields
        OpenStruct.new(id: 42, data: { "kind" => kind, "workflow_rule" => payload })
      end

      def raw_creative(payload)
        OpenStruct.new(id: 42, data: { "kind" => "workflow_rule", "workflow_rule" => payload })
      end

      def rule_payload(overrides)
        {
          "on" => "comment_created",
          "handler" => { "type" => "human" }
        }.merge(overrides)
      end
    end
  end
end
