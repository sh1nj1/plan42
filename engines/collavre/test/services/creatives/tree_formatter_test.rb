require "test_helper"

module Creatives
  class TreeFormatterTest < ActiveSupport::TestCase
    test "formats single root with header" do
      root = Creative.new(id: 1, description: "Root", progress: 0.5)

      formatter = Creatives::TreeFormatter.new(use_permissions: false)
      result = formatter.format(root)

      assert_includes result, "<!-- format: [id] description (progress%) -->"
      assert_includes result, "- [1] Root (50%)"
    end

    test "formats without header when include_header is false" do
      root = Creative.new(id: 1, description: "Root", progress: 0.5)

      formatter = Creatives::TreeFormatter.new(include_header: false, use_permissions: false)
      result = formatter.format(root)

      refute_includes result, "<!-- format:"
      assert_includes result, "- [1] Root (50%)"
    end

    test "formats tree with depth correctly" do
      root = Creative.new(id: 1, description: "Root", progress: 0.0)
      child1 = Creative.new(id: 2, description: "Child1", progress: 1.0, parent: root)
      child2 = Creative.new(id: 3, description: "Child2", progress: 0.0, parent: root)
      child2_1 = Creative.new(id: 4, description: "Child2-1", progress: 0.0, parent: child2)

      def root.children; [ @child1, @child2 ]; end
      def child2.children; [ @child2_1 ]; end
      def child1.children; []; end
      def child2_1.children; []; end

      root.instance_variable_set(:@child1, child1)
      root.instance_variable_set(:@child2, child2)
      child2.instance_variable_set(:@child2_1, child2_1)

      formatter = Creatives::TreeFormatter.new(use_permissions: false)
      result = formatter.format(root)

      expected = <<~TEXT.chomp
        <!-- format: [id] description (progress%) -->
        - [1] Root (0%)
          - [2] Child1 (100%)
          - [3] Child2 (0%)
            - [4] Child2-1 (0%)
      TEXT

      assert_equal expected, result
    end

    test "formats array of roots correctly" do
      root1 = Creative.new(id: 1, description: "Root1", progress: 0.0)
      child1 = Creative.new(id: 2, description: "Child1", progress: 1.0, parent: root1)
      root2 = Creative.new(id: 3, description: "Root2", progress: 1.0)

      def root1.children; [ @child1 ]; end
      def child1.children; []; end
      def root2.children; []; end

      root1.instance_variable_set(:@child1, child1)

      formatter = Creatives::TreeFormatter.new(use_permissions: false)
      result = formatter.format([ root1, root2 ])

      expected = <<~TEXT.chomp
        <!-- format: [id] description (progress%) -->
        - [1] Root1 (0%)
          - [2] Child1 (100%)
        - [3] Root2 (100%)
      TEXT

      assert_equal expected, result
    end

    test "respects max_depth" do
      root = Creative.new(id: 1, description: "Root", progress: 0.0)
      child = Creative.new(id: 2, description: "Child", progress: 0.0, parent: root)
      grandchild = Creative.new(id: 3, description: "Grandchild", progress: 0.0, parent: child)

      def root.children; [ @child ]; end
      def child.children; [ @grandchild ]; end
      def grandchild.children; []; end

      root.instance_variable_set(:@child, child)
      child.instance_variable_set(:@grandchild, grandchild)

      formatter = Creatives::TreeFormatter.new(max_depth: 1, use_permissions: false)
      result = formatter.format(root)

      assert_includes result, "[1] Root"
      assert_includes result, "[2] Child"
      refute_includes result, "Grandchild"
    end

    test "formats tree correctly with manually set children association" do
      root = Creative.new(id: 1, description: "Root", progress: 0.0)
      child = Creative.new(id: 2, description: "Child", progress: 0.0, parent: root)

      root.association(:children).target = [ child ]
      child.association(:children).target = []

      formatter = Creatives::TreeFormatter.new(use_permissions: false)
      result = formatter.format(root)

      assert_includes result, "- [1] Root (0%)"
      assert_includes result, "  - [2] Child (0%)"
    end

    test "plain_description strips HTML" do
      creative = Creative.new(description: "<b>Bold</b> text")
      result = Creatives::TreeFormatter.plain_description(creative)
      assert_equal "Bold text", result
    end
  end
end
