require "test_helper"

module Creatives
  class TreeFormatterTest < ActiveSupport::TestCase
    test "formats single root correctly" do
      root = Creative.new(id: 1, description: "Root", progress: 0.5)

      formatter = Creatives::TreeFormatter.new
      result = formatter.format(root)

      expected = <<~TEXT.chomp
        - {"id":1,"progress":0.5,"desc":"Root"}
      TEXT

      assert_equal expected, result
    end

    test "formats tree with depth correctly" do
      root = Creative.new(id: 1, description: "Root", progress: 0.0)
      child1 = Creative.new(id: 2, description: "Child1", progress: 1.0, parent: root)
      child2 = Creative.new(id: 3, description: "Child2", progress: 0.0, parent: root)
      child2_1 = Creative.new(id: 4, description: "Child2-1", progress: 0.0, parent: child2)

      # Mock children association since these are not saved records
      def root.children; [ @child1, @child2 ]; end
      def child2.children; [ @child2_1 ]; end
      def child1.children; []; end
      def child2_1.children; []; end

      root.instance_variable_set(:@child1, child1)
      root.instance_variable_set(:@child2, child2)
      child2.instance_variable_set(:@child2_1, child2_1)

      formatter = Creatives::TreeFormatter.new
      result = formatter.format(root)

      expected = <<~TEXT.chomp
        - {"id":1,"progress":0.0,"desc":"Root"}
            - {"id":2,"progress":1.0,"desc":"Child1"}
            - {"id":3,"progress":0.0,"desc":"Child2"}
                - {"id":4,"progress":0.0,"desc":"Child2-1"}
      TEXT

      assert_equal expected, result
    end

    test "formats array of roots correctly" do
      root1 = Creative.new(id: 1, description: "Root1", progress: 0.0)
      child1 = Creative.new(id: 2, description: "Child1", progress: 1.0, parent: root1)
      root2 = Creative.new(id: 3, description: "Root2", progress: 1.0)

      # Mock children
      def root1.children; [ @child1 ]; end
      def child1.children; []; end
      def root2.children; []; end

      root1.instance_variable_set(:@child1, child1)

      formatter = Creatives::TreeFormatter.new
      result = formatter.format([ root1, root2 ])

      expected = <<~TEXT.chomp
        - {"id":1,"progress":0.0,"desc":"Root1"}
            - {"id":2,"progress":1.0,"desc":"Child1"}
        - {"id":3,"progress":1.0,"desc":"Root2"}
      TEXT

      assert_equal expected, result
    end
    test "formats tree correctly with manually set children association" do
      root = Creative.new(id: 1, description: "Root", progress: 0.0)
      child = Creative.new(id: 2, description: "Child", progress: 0.0, parent: root)

      # Manually set the association target as we do in GeminiParentRecommender
      root.association(:children).target = [ child ]
      child.association(:children).target = [] # Ensure recursion stops without db lookup

      formatter = Creatives::TreeFormatter.new
      result = formatter.format(root)

      expected = <<~TEXT.chomp
        - {"id":1,"progress":0.0,"desc":"Root"}
            - {"id":2,"progress":0.0,"desc":"Child"}
      TEXT

      assert_equal expected, result
    end
  end
end
