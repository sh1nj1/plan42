require "test_helper"

class CreativesControllerSlideViewTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(email: "slide_owner@example.com", password: TEST_PASSWORD, name: "Slide Owner")
    sign_in_as(@owner, password: TEST_PASSWORD)

    Current.set(user: @owner) do
      @root = Creative.create!(user: @owner, description: "Slide Root")
      # Build a small but non-trivial tree:
      #   root
      #     a (sequence implicit)
      #       a1
      #       a2
      #     b
      #       b1
      @a = Creative.create!(user: @owner, parent: @root, description: "a")
      @b = Creative.create!(user: @owner, parent: @root, description: "b")
      @a1 = Creative.create!(user: @owner, parent: @a, description: "a1")
      @a2 = Creative.create!(user: @owner, parent: @a, description: "a2")
      @b1 = Creative.create!(user: @owner, parent: @b, description: "b1")
    end
    Creative.rebuild!
  end

  test "slide_view renders successfully" do
    get collavre.slide_view_creative_path(@root)
    assert_response :success
  end

  test "build_slide_ids returns the same DFS-by-sequence order as a recursive walk" do
    controller = build_controller_for(@root)
    Current.set(user: @owner) do
      controller.send(:build_slide_ids, @root)
    end
    actual_ids = controller.instance_variable_get(:@slide_ids)

    expected_ids = recursive_reference_walk(@root, @owner)
    assert_equal expected_ids, actual_ids
  end

  test "build_slide_ids handles linked children via origin" do
    other = User.create!(email: "slide_other@example.com", password: TEST_PASSWORD, name: "Other")
    origin = nil
    origin_child = nil
    Current.set(user: other) do
      origin = Creative.create!(user: other, description: "origin")
      origin_child = Creative.create!(user: other, parent: origin, description: "origin_child")
    end
    CreativeShare.create!(creative: origin, user: @owner, permission: :read)

    linked = nil
    Current.set(user: @owner) do
      linked = Creative.create!(user: @owner, origin: origin, description: "linked")
    end
    Creative.rebuild!

    controller = build_controller_for(linked)
    Current.set(user: @owner) do
      controller.send(:build_slide_ids, linked)
    end
    actual_ids = controller.instance_variable_get(:@slide_ids)

    expected_ids = recursive_reference_walk(linked, @owner)
    assert_equal expected_ids, actual_ids
    assert_includes actual_ids, origin_child.id
  end

  test "build_slide_ids issues a bounded number of queries regardless of tree size" do
    # Add a wider, deeper tree to amplify any per-node query cost.
    Current.set(user: @owner) do
      4.times do |i|
        node = Creative.create!(user: @owner, parent: @b1, description: "deep-#{i}")
        4.times do |j|
          Creative.create!(user: @owner, parent: node, description: "deep-#{i}-#{j}")
        end
      end
    end
    Creative.rebuild!

    controller = build_controller_for(@root)

    queries = []
    callback = ->(_n, _s, _f, _id, payload) {
      sql = payload[:sql]
      next if payload[:name] == "SCHEMA"
      next if sql.start_with?("BEGIN", "COMMIT", "SAVEPOINT", "RELEASE", "ROLLBACK")
      queries << sql
    }
    Current.set(user: @owner) do
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        controller.send(:build_slide_ids, @root)
      end
    end

    # Generous upper bound: O(depth) queries plus a few permission lookups.
    # The pre-fix recursion grew linearly with node count and would blow past
    # this for the ~14-node tree above (>= 28 queries).
    assert_operator queries.size, :<=, 25,
      "expected bounded query count, got #{queries.size}:\n#{queries.join("\n")}"
  end

  private

  def build_controller_for(creative)
    controller = Collavre::CreativesController.new
    controller.instance_variable_set(:@creative, creative)
    controller.instance_variable_set(:@slide_ids, [])
    controller
  end

  # Mirrors the pre-fix implementation so we can assert that the optimized
  # version produces an identical result.
  def recursive_reference_walk(root, user)
    ids = []
    visit = ->(node) {
      return unless node.has_permission?(user, :read)
      ids << node.id
      children = node.children.order(:sequence).to_a
      if node.origin_id.present?
        Current.set(user: user) do
          linked = node.linked_children
          children = (children + linked).uniq.sort_by(&:sequence)
        end
      end
      children.each { |c| visit.call(c) }
    }
    Current.set(user: user) do
      visit.call(root)
    end
    ids
  end
end
