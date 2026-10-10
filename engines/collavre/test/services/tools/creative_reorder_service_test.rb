require "test_helper"

module Collavre
  module Tools
    class CreativeReorderServiceTest < ActiveSupport::TestCase
      setup do
        @user = User.create!(name: "Reorder User", email: "test_reorder@example.com", password: "password123")
        Current.user = @user
        @parent = Creative.create!(description: "Parent", user: @user)
        @a = Creative.create!(description: "A", user: @user, parent: @parent)
        @b = Creative.create!(description: "B", user: @user, parent: @parent)
        @c = Creative.create!(description: "C", user: @user, parent: @parent)
      end

      teardown do
        Current.user = nil
      end

      test "resequences children to the given order" do
        result = CreativeReorderService.new.call(parent_id: @parent.id, ordered_ids: "#{@c.id}, #{@a.id},#{@b.id}")

        assert result[:success], "Expected success but got: #{result[:error]}"
        assert_equal [ @c.id, @a.id, @b.id ], result[:ordered_ids]
        assert_equal [ @c.id, @a.id, @b.id ], @parent.children.order(:sequence).pluck(:id)
      end

      test "accepts an array of ids" do
        result = CreativeReorderService.new.call(parent_id: @parent.id, ordered_ids: [ @b.id, @c.id, @a.id ])

        assert result[:success]
        assert_equal [ @b.id, @c.id, @a.id ], @parent.children.order(:sequence).pluck(:id)
      end

      test "rejects an incomplete list without changing order" do
        before = @parent.children.order(:sequence).pluck(:id)

        result = CreativeReorderService.new.call(parent_id: @parent.id, ordered_ids: "#{@c.id},#{@a.id}")

        assert_match "every direct child", result[:error]
        assert_equal [ @b.id ], result[:missing_ids]
        assert_equal before, @parent.children.order(:sequence).pluck(:id)
      end

      test "rejects ids that are not children" do
        other = Creative.create!(description: "Other", user: @user)

        result = CreativeReorderService.new.call(parent_id: @parent.id, ordered_ids: [ @a.id, @b.id, @c.id, other.id ])

        assert_equal [ other.id ], result[:unknown_ids]
        assert_equal @user.id, other.reload.user_id
        assert_nil other.parent_id
      end

      test "rejects duplicates and non-integer ids" do
        assert_match "duplicates", CreativeReorderService.new.call(parent_id: @parent.id, ordered_ids: [ @a.id, @a.id, @b.id, @c.id ])[:error]
        assert_match "integer", CreativeReorderService.new.call(parent_id: @parent.id, ordered_ids: "a,b")[:error]
      end

      test "rejects a user without write permission" do
        stranger = User.create!(name: "Stranger", email: "stranger_reorder@example.com", password: "password123")

        result = Current.set(user: stranger) do
          CreativeReorderService.new.call(parent_id: @parent.id, ordered_ids: [ @c.id, @b.id, @a.id ])
        end

        assert_match "No write permission", result[:error]
        assert_equal [ @a.id, @b.id, @c.id ], @parent.children.order(:sequence).pluck(:id)
      end
    end
  end
end
