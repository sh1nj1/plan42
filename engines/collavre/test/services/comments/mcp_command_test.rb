require "test_helper"

module Collavre
  module Comments
    class McpCommandTest < ActiveSupport::TestCase
      setup do
        @creative = creatives(:tshirt)
        @user = users(:one)
        @topic = Topic.create!(creative: @creative, user: @user, name: "Test Topic")
        @tool = {
          name: "run_sql_query",
          description: "Run a SQL query",
          params: [
            { name: "query", type: "string", required: true },
            { name: "limit", type: "integer", required: false }
          ]
        }
        @mock_service = Minitest::Mock.new
      end

      test "merge_with_defaults returns explicit args when no creative" do
        comment = create_comment("/run_sql_query #{JSON.generate(query: 'select 1')}")
        cmd = McpCommand.new(comment: comment, user: @user, tool: @tool, meta_tool_service: @mock_service)

        result = cmd.send(:merge_with_defaults, { "query" => "select 1" })
        assert_equal({ "query" => "select 1" }, result)
      end

      test "merge_with_defaults returns explicit args when creative has no tool defaults" do
        comment = create_comment("/run_sql_query #{JSON.generate(query: 'select 1')}")
        cmd = McpCommand.new(comment: comment, user: @user, tool: @tool, creative: @creative, meta_tool_service: @mock_service)

        result = cmd.send(:merge_with_defaults, { "query" => "select 1" })
        assert_equal({ "query" => "select 1" }, result)
      end

      test "merge_with_defaults applies creative defaults for missing args" do
        @creative.update!(data: { "tools" => { "run_sql_query" => { "query" => "select * from patient", "limit" => 100 } } })

        comment = create_comment("/run_sql_query")
        cmd = McpCommand.new(comment: comment, user: @user, tool: @tool, creative: @creative, meta_tool_service: @mock_service)

        result = cmd.send(:merge_with_defaults, {})
        assert_equal({ "query" => "select * from patient", "limit" => 100 }, result)
      end

      test "merge_with_defaults lets explicit args override defaults" do
        @creative.update!(data: { "tools" => { "run_sql_query" => { "query" => "select * from patient", "limit" => 100 } } })

        comment = create_comment('/run_sql_query {"query":"select count(*) from patient"}')
        cmd = McpCommand.new(comment: comment, user: @user, tool: @tool, creative: @creative, meta_tool_service: @mock_service)

        result = cmd.send(:merge_with_defaults, { "query" => "select count(*) from patient" })
        assert_equal "select count(*) from patient", result["query"]
        assert_equal 100, result["limit"]
      end

      test "merge_with_defaults partial override preserves remaining defaults" do
        @creative.update!(data: {
          "tools" => {
            "run_sql_query" => { "query" => "select * from patient", "limit" => 100 }
          }
        })

        comment = create_comment('/run_sql_query {"limit":50}')
        cmd = McpCommand.new(comment: comment, user: @user, tool: @tool, creative: @creative, meta_tool_service: @mock_service)

        result = cmd.send(:merge_with_defaults, { "limit" => 50 })
        assert_equal "select * from patient", result["query"]
        assert_equal 50, result["limit"]
      end

      test "parsed_arguments uses defaults when no args provided" do
        @creative.update!(data: { "tools" => { "run_sql_query" => { "query" => "select * from patient" } } })

        comment = create_comment("/run_sql_query")
        cmd = McpCommand.new(comment: comment, user: @user, tool: @tool, creative: @creative, meta_tool_service: @mock_service)

        result = cmd.send(:parsed_arguments)
        assert_equal({ "query" => "select * from patient" }, result)
      end

      test "returns nil for non-matching commands" do
        comment = create_comment("Hello world")
        cmd = McpCommand.new(comment: comment, user: @user, tool: @tool, creative: @creative, meta_tool_service: @mock_service)

        assert_nil cmd.call
      end

      test "format_response renders markdown body when result has markdown key" do
        comment = create_comment("/run_sql_query")
        cmd = McpCommand.new(comment: comment, user: @user, tool: @tool, meta_tool_service: @mock_service)

        result = cmd.send(:format_response, { result: { "markdown" => "# h1\n\n## h2\n" } })

        assert_includes result, "<details open><summary>run_sql_query response</summary>"
        assert_includes result, "# h1"
        assert_includes result, "## h2"
        refute_includes result, "<pre><code>"
        refute_includes result, "\"markdown\""
      end

      test "format_response falls back to JSON when result has no markdown key" do
        comment = create_comment("/run_sql_query")
        cmd = McpCommand.new(comment: comment, user: @user, tool: @tool, meta_tool_service: @mock_service)

        result = cmd.send(:format_response, { result: { "rows" => [ { "id" => 1 } ] } })

        assert_includes result, "<pre><code>"
        assert_includes result, "&quot;rows&quot;"
      end

      test "format_response falls back to JSON when markdown value is blank" do
        comment = create_comment("/run_sql_query")
        cmd = McpCommand.new(comment: comment, user: @user, tool: @tool, meta_tool_service: @mock_service)

        result = cmd.send(:format_response, { result: { "markdown" => "" } })

        assert_includes result, "<pre><code>"
      end

      test "format_response falls back to JSON when markdown value is not a string" do
        comment = create_comment("/run_sql_query")
        cmd = McpCommand.new(comment: comment, user: @user, tool: @tool, meta_tool_service: @mock_service)

        result = cmd.send(:format_response, { result: { "markdown" => { "nested" => true } } })

        assert_includes result, "<pre><code>"
      end

      test "format_response renders markdown when result uses symbol keys" do
        comment = create_comment("/run_sql_query")
        cmd = McpCommand.new(comment: comment, user: @user, tool: @tool, meta_tool_service: @mock_service)

        result = cmd.send(:format_response, { result: { markdown: "# h1\n\n## h2\n" } })

        assert_includes result, "<details open><summary>run_sql_query response</summary>"
        assert_includes result, "# h1"
        assert_includes result, "## h2"
        refute_includes result, "<pre><code>"
        refute_includes result, "\"markdown\""
      end

      test "format_response renders markdown when result is JSON string with markdown key" do
        comment = create_comment("/run_sql_query")
        cmd = McpCommand.new(comment: comment, user: @user, tool: @tool, meta_tool_service: @mock_service)

        json_string = JSON.generate({ markdown: "# h1\n\n## h2\n" })
        result = cmd.send(:format_response, { result: json_string })

        assert_includes result, "<details open><summary>run_sql_query response</summary>"
        assert_includes result, "# h1"
        refute_includes result, "<pre><code>"
      end

      private

      def create_comment(content)
        Collavre::Comment.create!(
          creative: @creative,
          topic: @topic,
          user: @user,
          content: content
        )
      end
    end
  end
end
