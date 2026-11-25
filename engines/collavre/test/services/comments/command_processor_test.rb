require "test_helper"

module Collavre
  module Comments
    class CommandProcessorTest < ActiveSupport::TestCase
      FakeCommand = Struct.new(:result) do
        def call = result
      end

      setup do
        @creative = creatives(:tshirt)
        @user = users(:one)
        @topic = Topic.create!(creative: @creative, user: @user, name: "Processor Topic")
      end

      test "plain comments return nil without building any command handler" do
        [ "hello world", "see a/b and /topic later", "", "   ", nil ].each do |content|
          comment = build_comment(content)

          refute_command_handlers_built do
            assert_nil CommandProcessor.new(comment: comment, user: @user).call,
                       "expected #{content.inspect} to skip command processing"
          end
        end
      end

      test "plain comments issue no SQL queries" do
        comment = build_comment("just a regular comment")

        queries = capture_sql { CommandProcessor.new(comment: comment, user: @user).call }

        assert_empty queries
      end

      test "slash commands with surrounding whitespace still run static commands" do
        comment = build_comment(%(  \n/topic "Whitespace Topic"  ))

        result = McpCommandBuilder.stub(:new, ->(**) { Struct.new(:commands).new([]) }) do
          CommandProcessor.new(comment: comment, user: @user).call
        end

        assert_match(/Whitespace Topic/, result)
        assert Topic.exists?(creative: @creative, name: "Whitespace Topic")
      end

      test "slash commands still reach MCP tool commands" do
        comment = build_comment("/some_tool arg=1")
        builder = Struct.new(:commands).new([ FakeCommand.new(nil), FakeCommand.new("tool ran") ])

        result = McpCommandBuilder.stub(:new, ->(**) { builder }) do
          CommandProcessor.new(comment: comment, user: @user).call
        end

        assert_equal "tool ran", result
      end

      test "unknown slash commands return nil after checking every handler" do
        comment = build_comment("/not_a_command")
        built = false

        result = McpCommandBuilder.stub(:new, ->(**) { built = true; Struct.new(:commands).new([]) }) do
          CommandProcessor.new(comment: comment, user: @user).call
        end

        assert built, "slash-prefixed comments must still build the MCP command list"
        assert_nil result
      end

      test "handler errors are returned as the response message" do
        comment = build_comment("/boom")

        result = McpCommandBuilder.stub(:new, ->(**) { raise "builder exploded" }) do
          CommandProcessor.new(comment: comment, user: @user).call
        end

        assert_equal "builder exploded", result
      end

      private

      def build_comment(content)
        Collavre::Comment.new(creative: @creative, topic: @topic, user: @user, content: content)
      end

      def refute_command_handlers_built(&block)
        fail_build = ->(**) { flunk("command handlers must not be built for plain comments") }
        McpCommandBuilder.stub(:new, fail_build) do
          TopicCommand.stub(:new, fail_build) do
            CalendarCommand.stub(:new, fail_build) do
              CompressCommand.stub(:new, fail_build, &block)
            end
          end
        end
      end

      def capture_sql
        queries = []
        callback = lambda do |*, payload|
          queries << payload[:sql] unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached]
        end
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
        queries
      end
    end
  end
end
