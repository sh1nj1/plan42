# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/workflow_creative_helper"

module Collavre
  module Workflow
    class ResolverTest < ActiveSupport::TestCase
      include WorkflowCreativeHelper

      test "orders workflows by effective context and rules by sequence" do
        inherited = create_workflow(description: "Inherited")
        own = create_workflow(description: "Own")
        parent = create_workflow_creative(description: "Parent", data: { "context_ids" => [ inherited.id ] })
        creative = create_workflow_creative(
          description: "Target", parent:, data: { "context_ids" => [ own.id ] }
        )
        inherited_rule = create_workflow_rule(parent: inherited, description: "Inherited rule")
        own_later = create_workflow_rule(parent: own, description: "Own later", sequence: 20)
        own_first = create_workflow_rule(parent: own, description: "Own first", sequence: 10)

        resolver = Resolver.new(context_for(creative))

        assert_equal [ own.id, inherited.id ], resolver.workflow_creative_ids
        assert_equal [ own_first.id, own_later.id, inherited_rule.id ], resolver.rules.map(&:creative_id)
      end

      test "uses a linked creative effective origin and excludes the shell and origin" do
        workflow = create_workflow
        origin = create_workflow_creative(
          description: "Origin", data: { "context_ids" => [ workflow.id ] }
        )
        linked = create_workflow_creative(description: "Linked", origin:)
        rule = create_workflow_rule(parent: workflow)

        resolver = Resolver.new(context_for(linked))

        assert_equal [ workflow.id ], resolver.workflow_creative_ids
        assert_equal [ rule.id ], resolver.rules.map(&:creative_id)
      end

      test "excludes disabled, current, origin, archived, and non-workflow context creatives" do
        kept = create_workflow(description: "Kept")
        disabled = create_workflow(description: "Disabled")
        archived = create_workflow(description: "Archived", archived_at: Time.current)
        note = create_workflow_creative(description: "Note", data: { "kind" => "note" })
        target = create_workflow_creative(description: "Target")
        target.update!(data: {
          "context_ids" => [ target.id, kept.id, disabled.id, archived.id, note.id ],
          "disabled_context_ids" => [ disabled.id ]
        })

        assert_equal [ kept.id ], Resolver.new(context_for(target)).workflow_creative_ids
      end

      test "ignores pinned creatives with persisted non-object metadata" do
        malformed = [ [], "workflow", 42, 1.5, true, false, nil ].map do |metadata|
          creative = create_workflow_creative(description: "Malformed context")
          Creative.where(id: creative.id).update_all([ "data = ?", metadata.to_json ])
          creative
        end
        workflow = create_workflow
        rule = create_workflow_rule(parent: workflow)
        target = target_with_context(*malformed, workflow)

        resolver = Resolver.new(context_for(target))

        assert_equal [ workflow.id ], resolver.workflow_creative_ids
        assert_equal [ rule.id ], resolver.rules.map(&:creative_id)
      end

      test "loads only active direct rule children and compacts invalid rules" do
        workflow = create_workflow
        valid = create_workflow_rule(parent: workflow)
        archived = create_workflow_rule(parent: workflow, archived_at: Time.current)
        invalid = create_workflow_rule(parent: workflow)
        invalid.update!(data: { "kind" => "workflow_rule", "workflow_rule" => {} })
        nested = create_workflow_rule(parent: valid)
        target = target_with_context(workflow)

        warnings = []
        Rails.logger.stub(:warn, ->(message) { warnings << message }) do
          assert_equal [ valid.id ], Resolver.new(context_for(target)).rules.map(&:creative_id)
        end

        assert warnings.any? { |message| message.include?(invalid.id.to_s) }
        refute_includes warnings.join, archived.id.to_s
        refute_includes warnings.join, nested.id.to_s
      end

      test "breaks cyclic inherited context and self-pinned workflow references" do
        workflow = create_workflow
        parent = create_workflow_creative(description: "Parent", data: { "context_ids" => [ workflow.id ] })
        target = create_workflow_creative(
          description: "Target", parent:, data: { "context_ids" => [ workflow.id ] }
        )
        parent.update_column(:parent_id, target.id)
        parent.association(:parent).reset
        target.association(:parent).reset
        workflow.update!(data: { "kind" => "workflow", "context_ids" => [ workflow.id ] })

        assert_equal [ workflow.id ], Resolver.new(context_for(target)).workflow_creative_ids
        assert_empty Resolver.new(context_for(workflow)).workflow_creative_ids
      end

      test "uses one active workflow query and one batched child query" do
        first = create_workflow(description: "First")
        second = create_workflow(description: "Second")
        create_workflow_rule(parent: first)
        create_workflow_rule(parent: second)
        target = target_with_context(first, second)
        sql = capture_creative_selects { Resolver.new(context_for(target)).rules }

        assert_equal 3, sql.length
        assert_equal 1, sql.count { |statement| statement.include?("parent_id") }
        assert_match(/ORDER BY .*parent_id.*sequence.*id/, sql.find { |statement| statement.include?("parent_id") })
      end

      test "caps valid parsed rules and warns with the discarded count" do
        workflow = create_workflow
        rules = Array.new(Resolver::MAX_RULES + 3) { create_workflow_rule(parent: workflow) }
        invalid = create_workflow_rule(parent: workflow)
        invalid.update!(data: { "kind" => "workflow_rule", "workflow_rule" => nil })
        warnings = []

        Rails.logger.stub(:warn, ->(message) { warnings << message }) do
          resolved = Resolver.new(context_for(target_with_context(workflow))).rules

          assert_equal rules.first(Resolver::MAX_RULES).map(&:id), resolved.map(&:creative_id)
        end

        assert warnings.any? { |message| message.include?("Discarded 3 valid rules") }
      end

      test "memoizes workflow IDs and rules without user lookups" do
        workflow = create_workflow
        create_workflow_rule(parent: workflow, handler: { "type" => "agent", "agent_ids" => [ 999_999 ] })
        resolver = Resolver.new(context_for(target_with_context(workflow)))
        resolver.workflow_creative_ids
        resolver.rules

        User.stub(:find_by, ->(*) { flunk "Resolver must not query users" }) do
          assert_empty capture_creative_selects {
            resolver.workflow_creative_ids
            resolver.rules
          }
        end
      end

      test "returns empty results when the context creative is absent" do
        resolver = Resolver.new("creative" => { "id" => -1 })

        assert_empty resolver.workflow_creative_ids
        assert_empty resolver.rules
      end

      private

      def context_for(creative)
        { "creative" => { "id" => creative.id } }
      end

      def target_with_context(*workflows)
        create_workflow_creative(
          description: "Target", data: { "context_ids" => workflows.map(&:id) }
        )
      end

      def capture_creative_selects
        statements = []
        callback = lambda do |*, payload|
          sql = payload[:sql]
          statements << sql if sql.start_with?("SELECT") && sql.include?('FROM "creatives"')
        end
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
        statements
      end
    end
  end
end
