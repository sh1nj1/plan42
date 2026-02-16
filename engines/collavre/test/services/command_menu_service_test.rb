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
  end
end
