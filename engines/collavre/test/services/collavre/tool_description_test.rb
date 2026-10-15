require "test_helper"

module Collavre
  class ToolDescriptionTest < ActiveSupport::TestCase
    BUILT_IN_TOOL = /\A(Collavre\w*::Tools::|Tools::MetaToolService\z)/

    test "built-in tools have a localized summary and details in every locale" do
      RailsMcpEngine::Engine.build_tools!
      names = ToolMeta.registry.select { |klass| klass.name&.match?(BUILT_IN_TOOL) }
                      .map { |klass| klass.tool_metadata[:name] }
      assert_includes names, "cron_list"

      %i[en ko].each do |locale|
        I18n.with_locale(locale) do
          names.each do |name|
            text = ToolDescription.for(name, "")
            assert text[:summary].present?, "#{name} lacks a #{locale} summary"
            assert text[:details].present?, "#{name} lacks #{locale} details"
          end
        end
      end
    end

    test "uses the current locale's translation instead of the declared description" do
      I18n.with_locale(:ko) do
        text = ToolDescription.for("cron_list", "List recurring scheduled jobs.")
        assert_equal I18n.t("collavre.tool_descriptions.cron_list.summary"), text[:summary]
        assert_equal I18n.t("collavre.tool_descriptions.cron_list.details"), text[:details]
      end
    end

    test "untranslated tools split the first sentence off as the summary" do
      text = ToolDescription.for("my_custom_tool", "Do a thing.\nIt works  well.\n\nMore info here.")
      assert_equal({ summary: "Do a thing.", details: "It works well.\n\nMore info here." }, text)
    end

    test "a single-sentence description has no details" do
      assert_equal({ summary: "Only one.", details: nil }, ToolDescription.for("my_custom_tool", "Only one."))
    end

    test "a blank description yields an empty summary" do
      assert_equal({ summary: "", details: nil }, ToolDescription.for("my_custom_tool", nil))
    end

    test "a name that is not a plain identifier is never used as an i18n key" do
      assert_equal({ summary: "Fallback.", details: nil }, ToolDescription.for("collavre.tool_categories", "Fallback."))
    end

    test "a translation without details keeps details empty" do
      I18n.backend.store_translations(:en, collavre: { tool_descriptions: { summary_only_tool: { summary: "Short." } } })
      assert_equal({ summary: "Short.", details: nil }, ToolDescription.for("summary_only_tool", "Long. Text."))
    end
  end
end
