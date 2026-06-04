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

    test "masks an archived ancestor since browse won't render it" do
      # Unarchiving a leaf only touches self_and_descendants, so a parent can
      # stay archived while the active leaf still surfaces in search.
      @mid.update!(archived_at: Time.current)

      result = Collavre::Creatives::BreadcrumbResolver.new([ @leaf.id ], user: @owner).call

      path = result[@leaf.id]
      # Depth preserved...
      assert_equal [ @root.id, @mid.id ], path.map { |p| p[:id] }
      # ...active readable root stays a normal crumb...
      assert_equal "Root Doc", path.first[:description]
      assert_nil path.first[:restricted]
      # ...but the archived ancestor is masked (a jump to it would dead-end).
      assert path.last[:restricted]
      assert_nil path.last[:description]
    end

    test "keeps an archived ancestor when archived rows are shown" do
      @mid.update!(archived_at: Time.current)

      result = Collavre::Creatives::BreadcrumbResolver.new([ @leaf.id ], user: @owner, include_archived: true).call

      path = result[@leaf.id]
      assert_equal "Mid", path.last[:description]
      assert_nil path.last[:restricted]
    end

    test "returns empty hash for creatives without ancestors" do
      assert_equal({}, Collavre::Creatives::BreadcrumbResolver.new([ @root.id ], user: @owner).call)
    end
  end
end
