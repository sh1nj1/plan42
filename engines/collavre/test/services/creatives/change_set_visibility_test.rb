# frozen_string_literal: true

require "test_helper"

module Collavre
  module Creatives
    class ChangeSetVisibilityTest < ActiveSupport::TestCase
      setup do
        @owner = users(:one)
        @reader = users(:two)
        @stranger = users(:three)
        Current.user = @owner
        @creative = Creative.create!(description: "<p>root</p>", user: @owner)
      end

      teardown { Current.user = nil }

      def change_set(user: @owner, status: "applied")
        CreativeChangeSet.create!(
          anchor_creative: @creative, anchor_source: "agent_topic", user: user,
          actor_kind: "agent", origin: "tool", status: status
        )
      end

      def change(creative_id, set: change_set, operation: "update", before: { "description" => "a" }, after: { "description" => "b" })
        set.creative_changes.create!(creative_id: creative_id, operation: operation, before: before, after: after, position: 0)
      end

      def independent(user, changes)
        ChangeSetVisibility.new(user: user).independent_changes(changes)
      end

      test "keeps changes of readable creatives and drops the rest" do
        hidden = Creative.create!(description: "<p>hidden</p>", user: @stranger)
        visible = change(@creative.id)
        concealed = change(hidden.id)

        assert_equal [ visible ], independent(@owner, [ visible, concealed ])
        assert_equal [ concealed ], independent(@stranger, [ visible, concealed ])
        assert_empty independent(nil, [ visible, concealed ])
      end

      test "matches judging each change alone" do
        child = Creative.create!(description: "<p>child</p>", user: @owner, parent: @creative)
        deleted = change(child.id, operation: "destroy", before: { "description" => "a", "parent_id" => @creative.id }, after: {})
        kept = change(@creative.id)
        child.destroy!

        [ @owner, @reader, nil ].each do |user|
          visibility = ChangeSetVisibility.new(user: user)
          alone = [ deleted, kept ].select { |item| visibility.changes([ item ]).any? }

          assert_equal alone, visibility.independent_changes([ deleted, kept ])
        end
      end

      test "a visible change does not lend visibility to a deleted descendant" do
        gone_parent_id = Creative.maximum(:id) + 1000
        gone_child_id = gone_parent_id + 1
        parent_change = change(gone_parent_id, operation: "destroy", before: { "description" => "a", "parent_id" => @creative.id }, after: {})
        child_change = change(gone_child_id, operation: "destroy", before: { "description" => "a", "parent_id" => gone_parent_id }, after: {})

        visibility = ChangeSetVisibility.new(user: @owner)

        assert_equal [ parent_change, child_change ], visibility.changes([ parent_change, child_change ])
        assert_empty visibility.changes([ child_change ])
        assert_equal [ parent_change ], visibility.independent_changes([ parent_change, child_change ])
      end

      test "a draft link removal stays visible to the user who may remove the link" do
        origin = Creative.create!(description: "<p>origin</p>", user: @owner)
        link = Creative.create!(origin: origin, user: @owner, parent: @creative)
        removal = change(link.id, set: change_set(status: "draft"), operation: "destroy",
                                  before: { "origin_id" => origin.id, "parent_id" => @creative.id }, after: {})

        assert_equal [ removal ], independent(@owner, [ removal ])
        assert_empty independent(@stranger, [ removal ])
      end
    end
  end
end
