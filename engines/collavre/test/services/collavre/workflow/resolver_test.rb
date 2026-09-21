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

      test "resolves shared workflow pins in pin order and deduplicates origins" do
        first = create_workflow(description: "First")
        second = create_workflow(description: "Second")
        first_link = first.create_linked_creative_for_user(users(:two))
        second_link = second.create_linked_creative_for_user(users(:two))
        first_rule = create_workflow_rule(parent: first)
        second_rule = create_workflow_rule(parent: second)
        target = target_with_context(second_link, first_link, second)

        resolver = Resolver.new(context_for(target))

        assert_equal [ second.id, first.id ], resolver.workflow_creative_ids
        assert_equal [ second_rule.id, first_rule.id ], resolver.rules.map(&:creative_id)
      end

      test "resolves chained linked workflow pins" do
        workflow = create_workflow
        shared = workflow.create_linked_creative_for_user(users(:two))
        chained = create_workflow_creative(description: "Chained link", origin: shared)
        rule = create_workflow_rule(parent: workflow)

        assert_equal [ rule.id ], Resolver.new(context_for(target_with_context(chained))).rules.map(&:creative_id)
      end

      test "excludes disabled and archived linked pins and archived workflow origins" do
        disabled = create_workflow
        archived_link_origin = create_workflow
        archived_origin = create_workflow(archived_at: Time.current)
        links = [ disabled, archived_link_origin, archived_origin ].map do |workflow|
          create_workflow_rule(parent: workflow)
          workflow.create_linked_creative_for_user(users(:two))
        end
        links[1].update!(archived_at: Time.current)
        target = target_with_context(*links)
        target.update!(data: target.data.merge("disabled_context_ids" => [ links.first.id ]))

        assert_empty Resolver.new(context_for(target)).rules
      end

      test "excludes self-pinned workflow aliases for direct and linked targets" do
        workflow = create_workflow
        linked = workflow.create_linked_creative_for_user(users(:two))
        create_workflow_rule(parent: workflow)
        workflow.update!(data: workflow.data.merge("context_ids" => [ linked.id ]))

        [ workflow, linked ].each do |target|
          resolver = Resolver.new(context_for(target))
          assert_empty resolver.workflow_creative_ids
          assert_empty resolver.rules
        end
      end

      test "batches origin lookups for shared workflow pins" do
        workflows = Array.new(3) { create_workflow }
        links = workflows.map { |workflow| workflow.create_linked_creative_for_user(users(:two)) }
        workflows.each { |workflow| create_workflow_rule(parent: workflow) }
        target = target_with_context(*links)
        sql = capture_creative_selects { Resolver.new(context_for(target)).rules }

        assert_equal 4, sql.length
        assert_equal 1, sql.count { |statement| statement.include?("parent_id") }
      end

      test "batches every origin depth for many chained workflow pins" do
        workflows = Array.new(8) { create_workflow }
        links = workflows.map do |workflow|
          3.times.reduce(workflow) do |origin, depth|
            create_workflow_creative(description: "Link #{depth}", origin:)
          end
        end
        rules = workflows.map { |workflow| create_workflow_rule(parent: workflow) }
        target = target_with_context(*links.reverse, workflows.first)
        resolver = Resolver.new(context_for(target))

        sql = capture_creative_selects do
          assert_equal workflows.reverse.map(&:id), resolver.workflow_creative_ids
          assert_equal rules.reverse.map(&:id), resolver.rules.map(&:creative_id)
        end

        assert_equal 6, sql.length
        assert_equal 1, sql.count { |statement| statement.include?("parent_id") }
      end

      test "bounds target parent hierarchy queries while preserving inherited pin order and disables" do
        own, near, far, disabled = Array.new(4) { create_workflow }
        rules = [ own, near, far ].map { |workflow| create_workflow_rule(parent: workflow) }
        root = create_workflow_creative(description: "Root", data: {
          "context_ids" => [ far.id, disabled.id ], "disabled_context_ids" => [ disabled.id ]
        })
        counts = [ 1, 12 ].map do |depth|
          parent = depth.times.reduce(root) do |ancestor, level|
            create_workflow_creative(description: "Ancestor #{level}", parent: ancestor)
          end
          parent.update!(data: { "context_ids" => [ near.id, far.id ] })
          target = create_workflow_creative(description: "Target", parent:, data: {
            "context_ids" => [ own.id, disabled.id ]
          })

          capture_creative_selects do
            resolver = Resolver.new(context_for(target))
            assert_equal [ own.id, near.id, far.id ], resolver.workflow_creative_ids
            assert_equal rules.map(&:id), resolver.rules.map(&:creative_id)
          end.length
        end

        assert_equal counts.first, counts.last
        assert_operator counts.last, :<=, 4
      end

      test "bounds linked target origin queries and inherits only from the final origin hierarchy" do
        own, inherited, disabled, shell_pin = Array.new(4) { create_workflow }
        rules = [ own, inherited ].map { |workflow| create_workflow_rule(parent: workflow) }
        ancestor = create_workflow_creative(description: "Ancestor", data: {
          "context_ids" => [ inherited.id, disabled.id ], "disabled_context_ids" => [ disabled.id ]
        })
        parent = 12.times.reduce(ancestor) do |previous, level|
          create_workflow_creative(description: "Parent #{level}", parent: previous)
        end
        origin = create_workflow_creative(description: "Origin", parent:, data: {
          "context_ids" => [ own.id, disabled.id ]
        })
        shell_parent = target_with_context(shell_pin)
        counts = [ 1, 12 ].map do |depth|
          target = depth.times.reduce(origin) do |previous, level|
            create_workflow_creative(
              description: "Linked target #{level}", origin: previous, parent: shell_parent,
              archived_at: (Time.current if level.zero?), data: { "context_ids" => [ shell_pin.id ] }
            )
          end

          capture_creative_selects do
            resolver = Resolver.new(context_for(target))
            assert_equal [ own.id, inherited.id ], resolver.workflow_creative_ids
            assert_equal rules.map(&:id), resolver.rules.map(&:creative_id)
          end.length
        end

        assert_equal counts.first, counts.last
        assert_operator counts.last, :<=, 5
      end

      test "bounds empty target hierarchy queries and keeps an ordinary root to one query" do
        root = create_workflow_creative(description: "Empty root")
        assert_equal 1, capture_creative_selects { assert_empty Resolver.new(context_for(root)).rules }.length

        counts = [ 1, 12 ].map do |depth|
          origin = depth.times.reduce(root) do |parent, level|
            create_workflow_creative(description: "Empty parent #{level}", parent:)
          end
          linked = depth.times.reduce(origin) do |previous, level|
            create_workflow_creative(description: "Empty link #{level}", origin: previous)
          end
          capture_creative_selects { assert_empty Resolver.new(context_for(linked)).rules }.length
        end

        assert_equal counts.first, counts.last
        assert_operator counts.last, :<=, 3
      end

      test "preserves the target cycle entry when preloading linked origins" do
        first_pin, second_pin = Array.new(2) { create_workflow }
        first = target_with_context(first_pin)
        second = create_workflow_creative(
          description: "Second", origin: first, data: { "context_ids" => [ second_pin.id ] }
        )
        linked = 8.times.reduce(second) do |origin, level|
          create_workflow_creative(description: "Cycle link #{level}", origin:)
        end
        Creative.where(id: first.id).update_all(origin_id: second.id)

        sql = capture_creative_selects do
          assert_equal [ second_pin.id ], Resolver.new(context_for(linked)).workflow_creative_ids
          assert_equal [ first_pin.id ], Resolver.new(context_for(first)).workflow_creative_ids
        end

        assert_operator sql.length, :<=, 6
      end

      test "traverses archived intermediate links without activating archived pins" do
        workflow = create_workflow
        archived_link = create_workflow_creative(
          description: "Archived link", origin: workflow, archived_at: Time.current
        )
        active_link = create_workflow_creative(description: "Active link", origin: archived_link)
        other = create_workflow
        target = target_with_context(archived_link, other, active_link)

        assert_equal [ other.id, workflow.id ], Resolver.new(context_for(target)).workflow_creative_ids
      end

      test "preserves cycle entry origins when linked pins converge on a cycle" do
        first = create_workflow(description: "First")
        second = create_workflow(description: "Second", origin: first)
        first_link = create_workflow_creative(description: "First link", origin: first)
        second_link = create_workflow_creative(description: "Second link", origin: second)
        Creative.where(id: first.id).update_all(origin_id: second.id)
        target = target_with_context(second, first_link, second_link, first)

        assert_equal [ second.id, first.id ], Resolver.new(context_for(target)).workflow_creative_ids
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

      [ [], "legacy", 42, 1.5, true, false, nil ].each do |metadata|
        test "inherits pins and disables through malformed target and parent #{metadata.inspect}" do
          kept = create_workflow
          disabled = create_workflow
          kept_rule = create_workflow_rule(parent: kept)
          create_workflow_rule(parent: disabled)
          grandparent = create_workflow_creative(description: "Grandparent", data: {
            "context_ids" => [ disabled.id, kept.id ], "disabled_context_ids" => [ disabled.id ]
          })
          parent = create_workflow_creative(description: "Parent", parent: grandparent)
          target = create_workflow_creative(description: "Target", parent: parent)
          linked = create_workflow_creative(description: "Linked target", origin: target)
          Creative.where(id: [ parent.id, target.id ]).update_all([ "data = ?", metadata.to_json ])

          [ target, linked ].each do |creative|
            resolver = Resolver.new(context_for(creative))
            assert_equal [ kept.id ], resolver.workflow_creative_ids
            assert_equal [ kept_rule.id ], resolver.rules.map(&:creative_id)
          end
        end
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

      test "follows current parent pointers when closure rows are stale" do
        old_pin, current_pin = Array.new(2) { create_workflow }
        old_parent = target_with_context(old_pin)
        current_parent = target_with_context(current_pin)
        target = create_workflow_creative(description: "Moved target", parent: old_parent)
        target.update_column(:parent_id, current_parent.id)

        assert_equal [ current_pin.id ], Resolver.new(context_for(target)).workflow_creative_ids
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
          statements << sql if sql.match?(/\A(?:SELECT|WITH)\b/) && sql.include?('FROM "creatives"')
        end
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
        statements
      end
    end
  end
end
