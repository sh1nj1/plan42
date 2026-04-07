require "test_helper"

module Collavre
  class CommandMenuServiceTest < ActiveSupport::TestCase
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

      work_item = items.find { |i| i[:name] == "work" }
      work_agent = work_item[:input_schema].find { |p| p[:name] == "agent_name" }
      assert_equal "mention", work_agent[:format], "work agent_name should have mention format"
    end

    test "creative command has no input_schema" do
      user = users(:one)
      items = CommandMenuService.new(user: user).items
      creative_item = items.find { |i| i[:name] == "creative" }
      assert_nil creative_item[:input_schema]
    end
  end
end
