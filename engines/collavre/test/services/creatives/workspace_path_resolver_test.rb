require "test_helper"

module Creatives
  class WorkspacePathResolverTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
    end

    test "returns the visible path in the user's own tree" do
      root = Creative.create!(user: @user, description: "Workspace root")
      branch = Creative.create!(user: @user, parent: root, description: "Workspace branch")
      leaf = Creative.create!(user: @user, parent: branch, description: "Workspace leaf")

      assert_equal [ root.id, branch.id, leaf.id ], resolve(leaf)
    end

    test "re-roots a shared origin path through the user's linked shell" do
      origin = Creative.create!(user: users(:two), description: "Shared origin")
      branch = Creative.create!(user: users(:two), parent: origin, description: "Shared branch")
      leaf = Creative.create!(user: users(:two), parent: branch, description: "Shared leaf")
      CreativeShare.create!(creative: origin, user: @user, permission: :read)
      origin.create_linked_creative_for_user(@user)

      shell = Creative.find_by!(user: @user, origin: origin)
      folder = Creative.create!(user: @user, description: "Local folder")
      shell.update!(parent: folder)

      assert_equal [ folder.id, shell.id, branch.id, leaf.id ], resolve(leaf)
    end

    test "never exposes an unreadable ancestor id" do
      restricted = Creative.create!(user: users(:two), description: "Restricted ancestor")
      shared_leaf = Creative.create!(user: users(:two), parent: restricted, description: "Shared leaf")
      CreativeShare.create!(creative: shared_leaf, user: @user, permission: :read)
      shared_leaf.create_linked_creative_for_user(@user)
      shell = Creative.find_by!(user: @user, origin: shared_leaf)

      path = resolve(shared_leaf)

      assert_equal [ shell.id ], path
      assert_not_includes path, restricted.id
      assert path.all? { |id| Creative.find(id).has_permission?(@user, :read) }
    end

    test "uses the deepest linked shell when several origin ancestors are linked" do
      origin = Creative.create!(user: users(:two), description: "Shared origin")
      branch = Creative.create!(user: users(:two), parent: origin, description: "Shared branch")
      leaf = Creative.create!(user: users(:two), parent: branch, description: "Shared leaf")
      CreativeShare.create!(creative: origin, user: @user, permission: :read)
      origin.create_linked_creative_for_user(@user)

      root_folder = Creative.create!(user: @user, description: "Root shell folder")
      Creative.find_by!(user: @user, origin: origin).update!(parent: root_folder)
      branch_folder = Creative.create!(user: @user, description: "Branch shell folder")
      branch_shell = Creative.create!(user: @user, origin: branch, parent: branch_folder)

      assert_equal [ branch_folder.id, branch_shell.id, leaf.id ], resolve(leaf)
    end

    test "rejects a reveal path through a linked shell whose origin is no longer readable" do
      restricted = Creative.create!(user: users(:two), description: "Revoked origin")
      shared_leaf = Creative.create!(user: users(:two), parent: restricted, description: "Directly shared leaf")
      ancestor_share = CreativeShare.create!(creative: restricted, user: @user, permission: :read)
      restricted.create_linked_creative_for_user(@user)
      stale_shell = Creative.find_by!(user: @user, origin: restricted)
      ancestor_share.destroy!
      CreativeShare.create!(creative: shared_leaf, user: @user, permission: :read)

      path = resolve(shared_leaf)

      assert_equal [ shared_leaf.id ], path
      assert_not_includes path, stale_shell.id
    end

    private

    def resolve(creative)
      Collavre::Creatives::WorkspacePathResolver.new(creative: creative, user: @user).call
    end
  end
end
