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

      test "does not reveal a child the caller cannot write" do
        editor = User.create!(name: "Editor", email: "editor_reorder@example.com", password: "password123")
        CreativeShare.create!(creative: @parent, user: editor, permission: :write)
        CreativeShare.create!(creative: @b, user: editor, permission: :no_access)

        result = Current.set(user: editor) do
          CreativeReorderService.new.call(parent_id: @parent.id, ordered_ids: [ @c.id, @a.id ])
        end

        assert_equal I18n.t("collavre.tools.creative_reorder.errors.child_write_permission"), result[:error]
        assert_nil result[:missing_ids]
        assert_equal [ @a.id, @b.id, @c.id ], @parent.children.order(:sequence).pluck(:id)
      end

      test "returns a generic error when the reorderer denies permission" do
        reorderer = Object.new
        def reorderer.reorder_multiple(**) = raise(::Creatives::Reorderer::PermissionError, "Permission denied")

        result = ::Creatives::Reorderer.stub(:new, ->(**) { reorderer }) do
          CreativeReorderService.new.call(parent_id: @parent.id, ordered_ids: [ @c.id, @b.id, @a.id ])
        end

        assert_equal I18n.t("collavre.tools.creative_reorder.errors.child_write_permission"), result[:error]
      end

      test "reports reorderer failures" do
        reorderer = Object.new
        def reorderer.reorder_multiple(**) = raise(::Creatives::Reorderer::Error, "boom")

        result = ::Creatives::Reorderer.stub(:new, ->(**) { reorderer }) do
          CreativeReorderService.new.call(parent_id: @parent.id, ordered_ids: [ @c.id, @b.id, @a.id ])
        end

        assert_equal "Failed to reorder: boom", result[:error]
      end

      test "localizes errors" do
        result = I18n.with_locale(:ko) do
          CreativeReorderService.new.call(parent_id: @parent.id, ordered_ids: [ @a.id, @a.id, @b.id, @c.id ])
        end

        assert_equal "ordered_ids에 중복된 id가 있습니다.", result[:error]
      end

      test "reorders the origin's children when given a linked creative" do
        link = Creative.create!(user: @user, origin_id: @parent.id)

        result = CreativeReorderService.new.call(parent_id: link.id, ordered_ids: [ @b.id, @a.id, @c.id ])

        assert result[:success], "Expected success but got: #{result[:error]}"
        assert_equal @parent.id, result[:parent_id]
        assert_equal [ @b.id, @a.id, @c.id ], @parent.children.order(:sequence).pluck(:id)
      end

      test "returns not found for an unknown parent" do
        result = CreativeReorderService.new.call(parent_id: 0, ordered_ids: [ @a.id ])

        assert_equal "Creative not found.", result[:error]
      end

      test "requires a current user" do
        Current.user = nil

        assert_raises(RuntimeError) { CreativeReorderService.new.call(parent_id: @parent.id, ordered_ids: [ @a.id ]) }
      end
    end
  end
end
