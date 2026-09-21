# frozen_string_literal: true

require "test_helper"

class CreativeCronFilterTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "cron-filter@example.com", password: TEST_PASSWORD, name: "Cron Filter")
    @root = Creative.create!(user: @user, description: "Automation root")
    @scheduled = Creative.create!(user: @user, parent: @root, description: "Scheduled child")
    @unscheduled = Creative.create!(user: @user, parent: @root, description: "Regular child")
    @task = SolidQueue::RecurringTask.create!(
      key: "cron_#{@scheduled.id}_#{SecureRandom.hex(4)}",
      class_name: "Collavre::CronActionJob",
      schedule: "0 9 * * *",
      static: false,
      arguments: []
    )
    sign_in_as(@user)
  end

  teardown do
    @task.destroy! if @task.persisted?
  end

  test "cron filter returns the scheduled creative with its ancestor and management badge" do
    get creatives_path(format: :json, has_cron: "true")

    assert_response :success
    nodes = flatten_nodes(JSON.parse(response.body).fetch("creatives"))
    assert_equal [ @root.id, @scheduled.id ].sort, nodes.pluck("id").sort
    refute_includes nodes.pluck("id"), @unscheduled.id

    scheduled_node = nodes.find { |node| node.fetch("id") == @scheduled.id }
    badge_html = scheduled_node.dig("templates", "progress_html")
    assert_includes badge_html, "creative-cron-badge"
    assert_includes badge_html, @task.schedule
  end

  test "html index preserves the cron filter for the client tree request" do
    get creatives_path(has_cron: "true")

    assert_response :success
    assert_select "[data-filter-state='cron'].active"
    assert_select "[data-filter-state='any-filter'].active"
    assert_select "[data-creatives--tree-url-value*='has_cron=true']"
  end

  test "cron filter resolves a linked creative task to its origin and linked placement" do
    origin = Creative.create!(user: @user, description: "Shared automation")
    linked = Creative.create!(user: @user, parent: @root, origin: origin)
    @task.destroy!
    @task = SolidQueue::RecurringTask.create!(
      key: "cron_#{linked.id}_#{SecureRandom.hex(4)}",
      class_name: "Collavre::CronActionJob",
      schedule: "30 10 * * *",
      static: false,
      arguments: []
    )

    get creatives_path(format: :json, has_cron: "true")

    assert_response :success
    nodes = flatten_nodes(JSON.parse(response.body).fetch("creatives"))
    assert_includes nodes.pluck("id"), origin.id
    assert_includes nodes.pluck("id"), linked.id
    [ origin.id, linked.id ].each do |creative_id|
      badge_html = nodes.find { |node| node.fetch("id") == creative_id }.dig("templates", "progress_html")
      assert_includes badge_html, "creative-cron-badge"
      assert_includes badge_html, @task.schedule
    end
  end

  private

  def flatten_nodes(nodes)
    nodes.flat_map do |node|
      [ node ] + flatten_nodes(node.dig("children_container", "nodes") || [])
    end
  end
end
