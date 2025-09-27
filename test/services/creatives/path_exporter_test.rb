require "test_helper"

module Creatives
  class PathExporterTest < ActiveSupport::TestCase
    test "returns all descendant paths including root" do
      user = users(:one)
      root = Creative.create!(user: user, description: "Root")
      child = Creative.create!(user: user, parent: root, description: "Child")
      Creative.create!(user: user, parent: child, description: "Grandchild")
      Creative.create!(user: user, parent: root, description: "Second")

      root.update_column(:progress, 0.25)
      child.update_column(:progress, 1.0)

      exporter = PathExporter.new(root)
      paths = exporter.paths

      assert_includes paths, "Root"
      assert_includes paths, "Root > Child"
      assert_includes paths, "Root > Child > Grandchild"
      assert_includes paths, "Root > Second"
      assert_equal 4, paths.size

      paths_with_ids = exporter.paths_with_ids
      assert_includes paths_with_ids, "[#{root.id}] Root"
      assert_includes paths_with_ids, "[#{child.id}] Child"

      paths_with_ids_and_progress = exporter.paths_with_ids_and_progress
      assert_includes paths_with_ids_and_progress, "[#{root.id}] Root (progress 25%)"
      assert_includes paths_with_ids_and_progress, "[#{child.id}] Child (progress 100%)"

      full_paths_with_ids = exporter.full_paths_with_ids
      assert_includes full_paths_with_ids, "[#{root.id}] Root"
      assert_includes full_paths_with_ids, "[#{root.id}] Root > [#{child.id}] Child"

      full_paths_with_ids_and_progress = exporter.full_paths_with_ids_and_progress
      assert_includes full_paths_with_ids_and_progress, "[#{root.id}] Root (progress 25%)"
      assert_includes(
        full_paths_with_ids_and_progress,
        "[#{root.id}] Root (progress 25%) > [#{child.id}] Child (progress 100%)"
      )

      assert_equal "Root > Child", exporter.path_for(child.id)
      assert_equal "[#{child.id}] Child", exporter.path_with_ids_for(child.id)
      assert_equal "[#{child.id}] Child (progress 100%)", exporter.path_with_ids_and_progress_for(child.id)
      assert_equal "[#{root.id}] Root > [#{child.id}] Child", exporter.full_path_with_ids_for(child.id)
      assert_equal(
        "[#{root.id}] Root (progress 25%) > [#{child.id}] Child (progress 100%)",
        exporter.full_path_with_ids_and_progress_for(child.id)
      )
    end
  end
end
