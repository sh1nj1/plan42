# frozen_string_literal: true

require "test_helper"

module Collavre
  module Creatives
    class ChangeSetRevertServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @root = Creative.create!(description: "Root", user: @user)
        @child = Creative.create!(description: "Before", user: @user, parent: @root)
        @change_set = recorded_update
        Current.reset
      end

      test "applies the inverse as a linked append-only change set" do
        result = ChangeSetRevertService.new(change_set: @change_set, user: @user).call

        assert_equal :applied, result.status
        assert_equal "Before", @child.reload.description
        assert_equal "reverted", @change_set.reload.status
        assert_equal result.change_set, @change_set.reverted_by
        assert_equal @change_set, result.change_set.reverts
        assert_equal "revert", result.change_set.origin
        assert_equal "After", result.change_set.creative_changes.sole.before.fetch("description")
        assert_equal "Before", result.change_set.creative_changes.sole.after.fetch("description")
      end

      test "reports a conflict without changing the Creative" do
        @child.update!(description: "Human follow-up")

        result = ChangeSetRevertService.new(change_set: @change_set, user: @user).call

        assert_equal :conflict, result.status
        assert_equal [ @child.id ], result.conflicts.pluck(:creative_id)
        assert_equal "Human follow-up", @child.reload.description
        assert_equal "applied", @change_set.reload.status
      end

      test "supports force and skip resolutions per Creative" do
        @child.update!(description: "Human follow-up")
        skipped = ChangeSetRevertService.new(
          change_set: @change_set,
          user: @user,
          resolutions: { @child.id => "skip" }
        ).call
        assert_equal :skipped, skipped.status
        assert_equal [ @child.id ], skipped.skipped

        forced = ChangeSetRevertService.new(
          change_set: @change_set,
          user: @user,
          resolutions: { @child.id => "force" }
        ).call
        assert_equal :applied, forced.status
        assert_equal "Before", @child.reload.description
      end

      test "skips Creatives without write permission" do
        result = ChangeSetRevertService.new(change_set: @change_set, user: users(:two)).call

        assert_equal :skipped, result.status
        assert_equal [ @child.id ], result.skipped
        assert_equal "After", @child.reload.description
      end

      test "does not revert synchronized or already reverted sets" do
        @change_set.update!(origin: "sync")
        assert_equal :not_revertible,
                     ChangeSetRevertService.new(change_set: @change_set, user: @user).call.status

        @change_set.update!(origin: "editor", status: "reverted")
        assert_equal :not_revertible,
                     ChangeSetRevertService.new(change_set: @change_set, user: @user).call.status
      end

      test "archives a Creative when reverting its creation" do
        created = nil
        creation = nil
        History.track(actor: @user, origin: :tool, anchor: @root) do
          created = Creative.create!(description: "Created", user: @user, parent: @root)
          creation = Current.change_set
        end
        Current.reset

        result = ChangeSetRevertService.new(change_set: creation, user: @user).call

        assert_equal :applied, result.status
        assert created.reload.archived?
      end

      test "reverting creation of a linked shell does not archive its existing origin" do
        linked = nil
        creation = nil
        History.track(actor: @user, origin: :tool, anchor: @root) do
          linked = Creative.create!(user: @user, origin: @child)
          creation = Current.change_set
        end
        Current.reset

        result = ChangeSetRevertService.new(change_set: creation, user: @user).call

        assert_equal :applied, result.status
        assert linked.reload.archived?
        assert_not @child.reload.archived?
      end

      test "restores a selected version without marking its source reverted" do
        @child.update!(description: "Newest")

        result = ChangeSetRestoreService.new(change_set: @change_set, user: @user).call

        assert_equal :applied, result.status
        assert_equal "After", @child.reload.description
        assert_equal "applied", @change_set.reload.status
        assert_equal @change_set, result.change_set.reverts
      end

      private

      def recorded_update
        change_set = nil
        History.track(actor: @user, origin: :editor, anchor: @root, anchor_source: :view_root) do
          @child.update!(description: "After")
          change_set = Current.change_set
        end
        change_set
      end
    end
  end
end
