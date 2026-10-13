require "test_helper"

class CreativeHierarchyFixturesTest < ActiveSupport::TestCase
  test "fixture closure rows match every parent chain" do
    expected = Creative.all.flat_map do |descendant|
      rows = []
      ancestor = descendant
      generation = 0
      while ancestor
        rows << [ ancestor.id, descendant.id, generation ]
        ancestor = ancestor.parent
        generation += 1
      end
      rows
    end

    assert_equal expected.sort, hierarchy_rows
  end

  test "fixture closure rows match closure tree rebuild output" do
    original = hierarchy_rows
    Creative.rebuild!

    assert_equal original, hierarchy_rows
  end

  test "moving a fixture subtree updates ancestors and rollback restores it" do
    original = hierarchy_rows
    Creative.transaction(requires_new: true) do
      creatives(:unconvert_target).update!(parent: creatives(:tshirt))

      assert_equal [ creatives(:tshirt).id, creatives(:unconvert_target).id,
                     creatives(:unconvert_child_one).id ].sort,
                   creatives(:unconvert_grandchild).ancestor_ids.sort
      raise ActiveRecord::Rollback
    end

    assert_equal original, hierarchy_rows
  end

  test "deleting a fixture leaf removes its closure rows" do
    target = creatives(:unconvert_grandchild)
    target.destroy!

    assert_empty Collavre::CreativeHierarchy.where(ancestor_id: target.id)
    assert_empty Collavre::CreativeHierarchy.where(descendant_id: target.id)
    assert_equal [ creatives(:unconvert_target).id, creatives(:unconvert_child_one).id,
                   creatives(:unconvert_child_two).id, creatives(:childless_creative).id ].sort,
                 creatives(:root_parent).descendant_ids.sort
  end

  test "host and core engine share the same fixture directory" do
    assert_equal File.realpath(Rails.root.join("test/fixtures")),
                 File.realpath(Rails.root.join("engines/collavre/test/fixtures"))
  end

  private

  def hierarchy_rows
    Collavre::CreativeHierarchy.pluck(:ancestor_id, :descendant_id, :generations).sort
  end
end

class NontransactionalCreativeHierarchyFixturesTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "fixture loading restores closure rows after a nontransactional mutation" do
    original = Collavre::CreativeHierarchy.pluck(:ancestor_id, :descendant_id, :generations).sort
    creatives(:unconvert_target).update!(parent: creatives(:tshirt))
    teardown_fixtures
    setup_fixtures

    assert_equal original, Collavre::CreativeHierarchy.pluck(:ancestor_id, :descendant_id, :generations).sort
  end
end
