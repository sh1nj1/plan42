require "test_helper"

class McpToolCategoriesTest < ActiveSupport::TestCase
  test "key_for resolves categories by tool name prefix" do
    assert_equal :creative, Collavre::McpToolCategories.key_for("creative_retrieval_service")
    assert_equal :topic, Collavre::McpToolCategories.key_for("topic_message_create")
    assert_equal :source, Collavre::McpToolCategories.key_for("collavre_source_read")
    assert_equal :cron, Collavre::McpToolCategories.key_for("cron_list")
    assert_equal :preview, Collavre::McpToolCategories.key_for("preview_attach")
    assert_equal :approval, Collavre::McpToolCategories.key_for("approval_request")
    assert_equal :other, Collavre::McpToolCategories.key_for("mystery_tool")
  end

  test "group orders categories, then custom and other, skipping empty ones" do
    tools = [
      { name: "mystery_tool" },
      { name: "topic_list" },
      { name: "creative_my_helper", custom: true },
      { name: "creative_update_service" },
      { name: "creative_create_service" }
    ]

    groups = Collavre::McpToolCategories.group(tools)

    assert_equal %i[creative topic custom other], groups.map { |group| group[:key] }
    assert_equal %w[creative_update_service creative_create_service], groups.first[:tools].map { |tool| tool[:name] }
    assert_equal [ "creative_my_helper" ], groups[2][:tools].map { |tool| tool[:name] }
    assert_equal I18n.t("collavre.tool_categories.creative"), groups.first[:label]
    assert_equal I18n.t("collavre.tool_categories.custom"), groups[2][:label]
    assert_equal I18n.t("collavre.tool_categories.other"), groups.last[:label]
  end

  test "group returns nothing for no tools" do
    assert_empty Collavre::McpToolCategories.group(nil)
  end

  test "register replaces an existing category and uses its label key" do
    original = Collavre::McpToolCategories.instance_variable_get(:@categories)
    Collavre::McpToolCategories.register(:cron, prefixes: %w[cron_ schedule_], label_key: "collavre.tool_categories.other")

    assert_equal :cron, Collavre::McpToolCategories.key_for("schedule_job")
    group = Collavre::McpToolCategories.group([ { name: "schedule_job" } ]).first
    assert_equal I18n.t("collavre.tool_categories.other"), group[:label]
    assert_equal 1, Collavre::McpToolCategories.instance_variable_get(:@categories).count { |c| c.key == :cron }
  ensure
    Collavre::McpToolCategories.instance_variable_set(:@categories, original)
  end
end
