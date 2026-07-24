require "test_helper"

# The browse tree (Creatives#index, JSON) must not issue queries proportional to
# the number of rendered nodes. Postgres is reached over the network, so every
# query costs a round trip and a per-node cost turns a page into seconds.
#
# The invariant asserted here is the shape of the cost, not an absolute number:
# rendering N more siblings must not cost O(N) more queries. Absolute counts move
# with unrelated features; the slope is what regresses into an outage.
class CreativesIndexQueryCountTest < ActionDispatch::IntegrationTest
  # Batched work still has some per-level cost, and a few queries scale with the
  # *result set* rather than the node count (e.g. a single WHERE IN grows its
  # bind list, not its query count). Allow a small constant; a regression to
  # per-node querying overshoots this by an order of magnitude.
  ALLOWED_DELTA = 10

  setup do
    @user = users(:one)
    sign_in_as(@user, password: "password")

    @parent = Creative.create!(user: @user, description: "Query count parent", sequence: 900)
  end

  test "query count does not scale with the number of rendered siblings" do
    add_children(5)
    baseline_nodes = 5
    get_tree # warm process-level caches (settings, schema) so they don't land in the baseline
    baseline = count_queries { get_tree }

    add_children(10)
    grown_nodes = 15
    grown = count_queries { get_tree }

    assert_equal grown_nodes, rendered_node_count,
      "the grown tree must actually render every sibling, or the counts compare nothing"

    delta = grown - baseline
    added = grown_nodes - baseline_nodes

    assert delta <= ALLOWED_DELTA,
      "rendering #{added} more siblings cost #{delta} more queries " \
      "(#{baseline} -> #{grown}, #{(delta.to_f / added).round(1)}/node). " \
      "Query count must not scale with node count; batch per level instead."
  end

  private

  # Each child gets a grandchild so `has_children` is true and the collapsed node
  # still has to answer "is there something to expand?" — the exact question the
  # old code answered by loading the whole child set per node.
  def add_children(count)
    count.times do
      child = Creative.create!(user: @user, parent: @parent, description: "child", sequence: 1)
      Creative.create!(user: @user, parent: child, description: "grandchild", sequence: 1)
    end
    @parent.reload
  end

  def get_tree
    get collavre.creatives_path(format: :json, id: @parent.id)
    assert_response :success
  end

  def rendered_node_count
    JSON.parse(response.body).fetch("creatives").length
  end

  # In production the AR query cache lives and dies with a single request. It
  # survives between requests here, which would let a measured request coast on
  # the previous one's cache and hide the very N+1 this asserts against.
  def count_queries
    Collavre::Creative.connection.clear_query_cache
    count = 0
    counter = lambda do |_name, _start, _finish, _id, payload|
      next if payload[:cached]
      next if %w[SCHEMA TRANSACTION].include?(payload[:name])

      count += 1
    end

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end
end
