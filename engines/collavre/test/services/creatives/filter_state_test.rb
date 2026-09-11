# frozen_string_literal: true

require "test_helper"

module Collavre
  module Creatives
    class FilterStateTest < ActiveSupport::TestCase
      test "is active for supported filters" do
        FilterState::FILTER_KEYS.each do |key|
          assert FilterState.new({ key => "true" }).active?, "Expected #{key} to activate filters"
        end
      end

      test "only treats the true comment feed as active" do
        assert FilterState.new({ comment: "true" }).active?
        refute FilterState.new({ comment: "false" }).active?
      end

      test "optionally includes archived visibility" do
        refute FilterState.new({ show_archived: "true" }).active?
        assert FilterState.new({ show_archived: "true" }, include_archived: true).active?
      end

      test "is inactive without filter parameters" do
        refute FilterState.new({}).active?
      end
    end
  end
end
