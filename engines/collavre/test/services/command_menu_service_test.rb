require "test_helper"

module Collavre
  class CommandMenuServiceTest < ActiveSupport::TestCase
    test "keep arguments are localized in parser order" do
      { en: "[--max 10] [@agent:] [goal]", ko: "[--max 10] [@에이전트:] [목표]" }.each do |locale, expected|
        I18n.with_locale(locale) do
          item = CommandMenuService.new(user: users(:one)).send(:keep_item)
          assert_equal expected, item[:args]
        end
      end
    end

    test "keep exposes localized optional inputs in parser order" do
      %i[en ko].each do |locale|
        I18n.with_locale(locale) do
          schema = CommandMenuService.new(user: users(:one)).send(:keep_item)[:input_schema]
          assert_equal %w[max agent_name goal], schema.map { |param| param[:name] }
          assert_equal "integer", schema.first[:type]
          assert_equal "keep_agent", schema.second[:format]
          assert_equal 1, schema.first[:minimum]
          assert_equal 50, schema.first[:maximum]
          schema.zip(%w[max agent goal]).each do |param, key|
            assert_not param[:required]
            assert_equal I18n.t("collavre.comments.keep_command.#{key}_hint", raise: true), param[:description]
          end
        end
      end
    end

    test "returns built-in calendar and topic items" do
      user = users(:one)
      items = CommandMenuService.new(user: user).items

      calendar_item = items.find { |i| i[:name] == "calendar" }
      topic_item = items.find { |i| i[:name] == "topic" }

      assert_not_nil calendar_item, "Should include calendar command"
      assert_equal "/calendar", calendar_item[:label]
      assert_includes calendar_item[:aliases], "/cal"

      assert_not_nil topic_item, "Should include topic command"
      assert_equal "/topic", topic_item[:label]
    end

    test "returns creative command with popup type" do
      user = users(:one)
      items = CommandMenuService.new(user: user).items

      creative_item = items.find { |i| i[:name] == "creative" }

      assert_not_nil creative_item, "Should include creative command"
      assert_equal "/creative", creative_item[:label]
      assert_equal "popup", creative_item[:type]
      assert_equal "creative_picker", creative_item[:popup_type]
    end

    test "format_args handles nil params" do
      service = CommandMenuService.new(user: users(:one))
      assert_nil service.send(:format_args, nil)
    end

    test "format_args handles array params" do
      service = CommandMenuService.new(user: users(:one))
      params = [
        { name: "query", required: true },
        { name: "limit", required: false }
      ]
      result = service.send(:format_args, params)
      assert_equal "query*, limit", result
    end

    test "format_args handles hash params with properties" do
      service = CommandMenuService.new(user: users(:one))
      params = {
        properties: { "name" => {}, "age" => {} },
        required: [ "name" ]
      }
      result = service.send(:format_args, params)
      assert_equal "name*, age", result
    end

    test "built-in commands include input_schema" do
      user = users(:one)
      items = CommandMenuService.new(user: user).items

      calendar_item = items.find { |i| i[:name] == "calendar" }
      assert_not_nil calendar_item[:input_schema], "Calendar should have input_schema"
      assert_equal 2, calendar_item[:input_schema].length

      date_param = calendar_item[:input_schema].find { |p| p[:name] == "date" }
      assert date_param[:required], "date should be required"
      assert_equal "string", date_param[:type]

      memo_param = calendar_item[:input_schema].find { |p| p[:name] == "memo" }
      assert_not memo_param[:required], "memo should be optional"
    end

    test "normalize_params converts array params" do
      service = CommandMenuService.new(user: users(:one))
      params = [
        { name: "query", type: "string", required: true, description: "Search query" },
        { name: "limit", type: "integer", required: false }
      ]
      result = service.send(:normalize_params, params)

      assert_equal 2, result.length
      assert_equal "query", result[0][:name]
      assert result[0][:required]
      assert_equal "integer", result[1][:type]
    end

    test "normalize_params converts hash params with properties" do
      service = CommandMenuService.new(user: users(:one))
      params = {
        properties: {
          "name" => { type: "string", description: "User name" },
          "active" => { type: "boolean" }
        },
        required: [ "name" ]
      }
      result = service.send(:normalize_params, params)

      assert_equal 2, result.length
      name_param = result.find { |p| p[:name] == "name" }
      assert name_param[:required]
      assert_equal "User name", name_param[:description]

      active_param = result.find { |p| p[:name] == "active" }
      assert_not active_param[:required]
      assert_equal "boolean", active_param[:type]
    end

    test "normalize_params returns nil for blank params" do
      service = CommandMenuService.new(user: users(:one))
      assert_nil service.send(:normalize_params, nil)
      assert_nil service.send(:normalize_params, [])
    end

    test "agent_name fields have mention format" do
      user = users(:one)
      items = CommandMenuService.new(user: user).items

      topic_item = items.find { |i| i[:name] == "topic" }
      agent_field = topic_item[:input_schema].find { |p| p[:name] == "agent_name" }
      assert_equal "mention", agent_field[:format], "topic agent_name should have mention format"
    end

    test "creative command has no input_schema" do
      user = users(:one)
      items = CommandMenuService.new(user: user).items
      creative_item = items.find { |i| i[:name] == "creative" }
      assert_nil creative_item[:input_schema]
    end

    test "tool_defaults_for returns nil when no creative" do
      service = CommandMenuService.new(user: users(:one))
      assert_nil service.send(:tool_defaults_for, "run_sql_query")
    end

    test "tool_defaults_for returns nil when creative has no tool defaults" do
      creative = creatives(:tshirt)
      service = CommandMenuService.new(user: users(:one), creative: creative)
      assert_nil service.send(:tool_defaults_for, "run_sql_query")
    end

    test "tool_defaults_for returns defaults from creative data" do
      creative = creatives(:tshirt)
      creative.update!(data: { "tools" => { "run_sql_query" => { "query" => "select * from patient", "limit" => 100 } } })
      service = CommandMenuService.new(user: users(:one), creative: creative)

      defaults = service.send(:tool_defaults_for, "run_sql_query")
      assert_equal({ "query" => "select * from patient", "limit" => 100 }, defaults)
    end

    test "apply_defaults_to_schema merges default_value into schema params" do
      service = CommandMenuService.new(user: users(:one))
      schema = [
        { name: "query", type: "string", required: true },
        { name: "limit", type: "integer", required: false },
        { name: "format", type: "string", required: false }
      ]
      defaults = { "query" => "select * from patient", "limit" => 100 }

      service.send(:apply_defaults_to_schema, schema, defaults)

      query_param = schema.find { |p| p[:name] == "query" }
      assert_equal "select * from patient", query_param[:default_value]

      limit_param = schema.find { |p| p[:name] == "limit" }
      assert_equal 100, limit_param[:default_value]

      format_param = schema.find { |p| p[:name] == "format" }
      assert_nil format_param[:default_value], "Params without defaults should not have default_value"
    end

    test "tool items show the localized summary and carry details for the more toggle" do
      tools = [ { name: "cron_list", description: "List recurring scheduled jobs. Long LLM text.", params: nil } ]
      McpService.stub(:available_tools, tools) do
        I18n.with_locale(:ko) do
          item = CommandMenuService.new(user: users(:one)).items.find { |i| i[:name] == "cron_list" }
          assert_equal I18n.t("collavre.tool_descriptions.cron_list.summary"), item[:description]
          assert_equal I18n.t("collavre.tool_descriptions.cron_list.details"), item[:details]
        end
      end
    end

    test "tool items without details omit the details key" do
      tools = [ { "name" => "my_tool", "description" => "Does one thing.", "params" => nil } ]
      McpService.stub(:available_tools, tools) do
        item = CommandMenuService.new(user: users(:one)).items.find { |i| i[:name] == "my_tool" }
        assert_equal "Does one thing.", item[:description]
        assert_not item.key?(:details)
      end
    end
  end
end
