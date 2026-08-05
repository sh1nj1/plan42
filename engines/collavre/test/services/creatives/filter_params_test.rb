require "test_helper"

module Collavre
  module Creatives
    class FilterParamsTest < ActiveSupport::TestCase
      test "active? is false for an empty params hash" do
        refute FilterParams.active?({})
      end

      test "active? is true when a display filter is present" do
        assert FilterParams.active?({ "search" => "hello" })
        assert FilterParams.active?({ "tags" => "urgent" })
        assert FilterParams.active?({ "min_progress" => "1" })
        assert FilterParams.active?({ "assignee_id" => "5" })
      end

      test "active? treats comment only as active when it equals 'true'" do
        assert FilterParams.active?({ "comment" => "true" })
        refute FilterParams.active?({ "comment" => "false" })
        refute FilterParams.active?({ "comment" => "" })
      end

      test "active? ignores blank values" do
        refute FilterParams.active?({ "search" => "", "tags" => nil })
      end

      test "show_archived counts for display but not for routing" do
        params = { "show_archived" => "true" }
        assert FilterParams.active?(params), "show_archived should light the active indicator"
        refute FilterParams.active?(params, FilterParams::ROUTING_KEYS),
          "show_archived must not route through FilterPipeline"
      end

      test "active? works with symbol-keyed and indifferent access params" do
        assert FilterParams.active?({ search: "hello" }.with_indifferent_access)
        assert FilterParams.active?(ActionController::Parameters.new(search: "hello"))
      end

      test "ROUTING_KEYS is DISPLAY_KEYS without show_archived" do
        assert_equal FilterParams::DISPLAY_KEYS - %w[show_archived], FilterParams::ROUTING_KEYS
        refute_includes FilterParams::ROUTING_KEYS, "show_archived"
      end
    end
  end
end
