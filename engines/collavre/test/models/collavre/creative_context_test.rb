# frozen_string_literal: true

require "test_helper"

module Collavre
  class CreativeContextTest < ActiveSupport::TestCase
    setup do
      @admin = users(:one)
      Collavre::Current.user = @admin

      @project = Creative.create!(description: "Project", user: @admin)
      @development = Creative.create!(description: "Development Rules", user: @admin, parent: @project)
      @goal = Creative.create!(description: "Goal", user: @admin, parent: @project)
      @features = Creative.create!(description: "Features", user: @admin, parent: @project)
      @feature_a = Creative.create!(description: "Feature A", user: @admin, parent: @features)
      @feature_b = Creative.create!(description: "Feature B", user: @admin, parent: @features)
      @rnd = Creative.create!(description: "R&D", user: @admin, parent: @project)
      @research_a = Creative.create!(description: "Research A", user: @admin, parent: @rnd)
    end

    test "context_ids returns empty array when no context configured" do
      assert_equal [], @feature_a.context_ids
    end

    [ [], [ { "context_ids" => [ 1 ] } ], "legacy", 42, 1.5, true, false, nil ].each do |metadata|
      test "context readers ignore persisted non-object metadata #{metadata.inspect}" do
        Creative.where(id: @feature_a.id).update_all([ "data = ?", metadata.to_json ])
        @feature_a.reload

        assert_empty @feature_a.context_ids
        assert_empty @feature_a.disabled_context_ids
        refute_predicate @feature_a, :inbox?
      end
    end

    test "context_ids returns configured IDs from data" do
      @features.update!(data: { "context_ids" => [ @development.id ] })
      assert_equal [ @development.id ], @features.context_ids
    end

    test "effective_context_ids inherits from parent" do
      @features.update!(data: { "context_ids" => [ @development.id ] })
      assert_includes @feature_a.effective_context_ids, @development.id
      assert_includes @feature_b.effective_context_ids, @development.id
    end

    test "effective_context_ids combines own and parent contexts" do
      @features.update!(data: { "context_ids" => [ @development.id ] })
      @feature_a.update!(data: { "context_ids" => [ @goal.id ] })

      effective = @feature_a.effective_context_ids
      assert_includes effective, @development.id
      assert_includes effective, @goal.id
    end

    test "effective_context_ids deduplicates" do
      @features.update!(data: { "context_ids" => [ @development.id ] })
      @feature_a.update!(data: { "context_ids" => [ @development.id, @goal.id ] })

      effective = @feature_a.effective_context_ids
      assert_equal 1, effective.count(@development.id)
    end

    test "effective_context_ids returns empty when no context in hierarchy" do
      assert_equal [], @feature_a.effective_context_ids
    end

    test "context_creatives returns Creative objects excluding self" do
      @features.update!(data: { "context_ids" => [ @development.id, @features.id ] })
      creatives = @features.context_creatives
      assert_includes creatives, @development
      refute_includes creatives, @features
    end

    # --- effective_disabled_context_ids ---

    test "effective_disabled_context_ids returns empty when nothing disabled" do
      assert_equal [], @feature_a.effective_disabled_context_ids
    end

    test "effective_disabled_context_ids returns own disabled IDs" do
      @features.update!(data: { "context_ids" => [ @development.id ], "disabled_context_ids" => [ @development.id ] })
      assert_equal [ @development.id ], @features.effective_disabled_context_ids
    end

    test "effective_disabled_context_ids inherits from parent" do
      @features.update!(data: { "context_ids" => [ @development.id ], "disabled_context_ids" => [ @development.id ] })
      assert_includes @feature_a.effective_disabled_context_ids, @development.id
    end

    test "effective_disabled_context_ids combines own and parent disabled" do
      @features.update!(data: { "context_ids" => [ @development.id ], "disabled_context_ids" => [ @development.id ] })
      @feature_a.update!(data: { "context_ids" => [ @goal.id ], "disabled_context_ids" => [ @goal.id ] })

      disabled = @feature_a.effective_disabled_context_ids
      assert_includes disabled, @development.id
      assert_includes disabled, @goal.id
    end

    test "effective_disabled_context_ids deduplicates" do
      @features.update!(data: { "disabled_context_ids" => [ @development.id ] })
      @feature_a.update!(data: { "disabled_context_ids" => [ @development.id ] })

      disabled = @feature_a.effective_disabled_context_ids
      assert_equal 1, disabled.count(@development.id)
    end

    test "R&D inherits different context than Features" do
      @features.update!(data: { "context_ids" => [ @development.id ] })
      @rnd.update!(data: { "context_ids" => [ @goal.id ] })

      assert_includes @feature_a.effective_context_ids, @development.id
      refute_includes @feature_a.effective_context_ids, @goal.id

      assert_includes @research_a.effective_context_ids, @goal.id
      refute_includes @research_a.effective_context_ids, @development.id
    end

    test "ordered_context_ids lists inherited contexts before own ones by default" do
      @features.update!(data: { "context_ids" => [ @development.id ] })
      @feature_a.update!(data: { "context_ids" => [ @goal.id, @rnd.id ] })

      assert_equal [ @development.id, @goal.id, @rnd.id ], @feature_a.ordered_context_ids
    end

    test "ordered_context_ids excludes self" do
      @feature_a.update!(data: { "context_ids" => [ @feature_a.id, @goal.id ] })

      assert_equal [ @goal.id ], @feature_a.ordered_context_ids
    end

    test "ordered_context_ids applies own context_order and appends unlisted contexts" do
      @features.update!(data: { "context_ids" => [ @development.id ] })
      @feature_a.update!(data: {
        "context_ids" => [ @goal.id, @rnd.id, @research_a.id ],
        "context_order" => [ @rnd.id, @development.id, 999_999 ]
      })

      assert_equal [ @rnd.id, @development.id, @goal.id, @research_a.id ], @feature_a.ordered_context_ids
    end

    test "ordered_context_ids inherits the nearest ancestor context_order" do
      @project.update!(data: { "context_order" => [ @goal.id ] })
      @features.update!(data: { "context_ids" => [ @development.id, @goal.id ], "context_order" => [ @goal.id, @development.id ] })

      assert_equal [ @goal.id, @development.id ], @feature_a.ordered_context_ids
      assert_equal [ @goal.id, @development.id ], @feature_a.effective_context_order
    end

    test "own context_order takes precedence over ancestors" do
      @features.update!(data: { "context_ids" => [ @development.id, @goal.id ], "context_order" => [ @goal.id ] })
      @feature_a.update!(data: { "context_order" => [ @development.id ] })

      assert_equal [ @development.id, @goal.id ], @feature_a.ordered_context_ids
    end

    test "context_order is empty for non-object metadata" do
      Creative.where(id: @feature_a.id).update_all([ "data = ?", "[]" ])

      assert_empty @feature_a.reload.context_order
    end
  end
end
