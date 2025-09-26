require "test_helper"

module Creatives
  class PathExporterTest < ActiveSupport::TestCase
    test "returns all descendant paths including root" do
      user = users(:one)
      root = Creative.create!(user: user, description: "Root")
      child = Creative.create!(user: user, parent: root, description: "Child")
      Creative.create!(user: user, parent: child, description: "Grandchild")
      Creative.create!(user: user, parent: root, description: "Second")

      paths = PathExporter.new(root).paths

      assert_includes paths, "Root"
      assert_includes paths, "Root > Child"
      assert_includes paths, "Root > Child > Grandchild"
      assert_includes paths, "Root > Second"
      assert_equal 4, paths.size
    end
  end
end
