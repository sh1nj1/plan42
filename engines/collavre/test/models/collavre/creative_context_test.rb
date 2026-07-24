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
  end
end
