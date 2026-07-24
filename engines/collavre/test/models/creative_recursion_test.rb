require "test_helper"

class CreativeRecursionTest < ActiveSupport::TestCase
  test "effective_attribute handles circular origin references gracefully" do
    user = users(:one)

    # Setup Cycle: A -> B -> A
    # Calling A.progress should not crash

    a = Creative.create!(description: "A", user: user)
    b = Creative.create!(description: "B", user: user)

    # origin_id is attr_readonly (immutable after create), so update! / update_columns
    # would raise. Inject the pathological cycle directly at the SQL level with
    # update_all, which bypasses the readonly guard — exactly what this defensive
    # test needs to exercise graceful handling of corrupt data.
    Creative.where(id: a.id).update_all(origin_id: b.id)
    Creative.where(id: b.id).update_all(origin_id: a.id)

    # Reload to ensure associations are fresh
    a.reload
    b.reload

    # This should return nil or self value, but NOT crash
    assert_nothing_raised do
      a.progress
    end
  end
end
