require "test_helper"

module Creatives
  class BreadcrumbResolverTest < ActiveSupport::TestCase
    setup do
      @owner = users(:one)
      @other = users(:two)

      @root = Creative.create!(user: @owner, description: "<b>Root</b> Doc")
      @mid = Creative.create!(user: @owner, parent: @root, description: "Mid")
      @leaf = Creative.create!(user: @owner, parent: @mid, description: "Leaf")
      @leaf.reload
    end

    test "returns ancestors ordered root to parent as plain text" do
      result = Collavre::Creatives::BreadcrumbResolver.new([ @leaf.id ], user: @owner).call

      path = result[@leaf.id]
      assert_equal [ @root.id, @mid.id ], path.map { |p| p[:id] }
      assert_equal "Root Doc", path.first[:description] # HTML stripped
      assert_equal "Mid", path.last[:description]
    end

    test "masks ancestors the user cannot read" do
      result = Collavre::Creatives::BreadcrumbResolver.new([ @leaf.id ], user: @other).call

      path = result[@leaf.id]
      # Depth is preserved so the result still reads as nested...
      assert_equal [ @root.id, @mid.id ], path.map { |p| p[:id] }
      # ...but inaccessible ancestor text is masked
      assert(path.all? { |p| p[:restricted] && p[:description].nil? })
    end

    test "returns empty hash for creatives without ancestors" do
      assert_equal({}, Collavre::Creatives::BreadcrumbResolver.new([ @root.id ], user: @owner).call)
    end
  end
end
