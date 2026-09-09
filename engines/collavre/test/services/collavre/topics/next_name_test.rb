# frozen_string_literal: true

require "test_helper"

module Collavre
  module Topics
    class NextNameTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = Collavre::Creative.create!(description: "Naming Host", user: @user)
        @prefix = I18n.t("collavre.topics.default_name_prefix")
      end

      test "starts at one on a creative with no generated names" do
        assert_equal "#{@prefix}1", NextName.for(@creative)
      end

      test "continues past the highest existing number rather than filling gaps" do
        @creative.topics.create!(name: "#{@prefix}1", user: @user)
        @creative.topics.create!(name: "#{@prefix}7", user: @user)

        assert_equal "#{@prefix}8", NextName.for(@creative)
      end

      test "ignores names that share the prefix but are not numbered" do
        @creative.topics.create!(name: "#{@prefix} planning", user: @user)

        assert_equal "#{@prefix}1", NextName.for(@creative)
      end

      # Names are unique per creative regardless of archive state, so reusing an
      # archived number would generate a name that cannot be saved.
      test "counts archived topics so it never proposes a name that already exists" do
        @creative.topics.create!(name: "#{@prefix}4", user: @user).archive!

        assert_equal "#{@prefix}5", NextName.for(@creative)
      end
    end
  end
end
