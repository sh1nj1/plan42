require "test_helper"

module Collavre
  module Comments
    class KeepCommandTest < ActiveSupport::TestCase
      setup do
        @creative = creatives(:tshirt)
        @user = users(:one)
        @topic = @creative.main_topic
      end

      test "starts a standalone loop with default routing and limit" do
        comment = command("/keep finish the work")
        assert_nil KeepCommand.new(comment: comment, user: @user).call
        comment.skip_dispatch = true
        comment.save!

        loop_data = @creative.reload.data.dig("trigger", "loop")
        assert_equal "keep", loop_data["source"]
        assert_equal "running", loop_data["state"]
        assert_equal 10, loop_data["max_iterations"]
        assert_equal "finish the work", loop_data["goal"]
        assert_equal @topic.id, loop_data["trigger_topic_id"]
        assert_nil loop_data["agent_id"]
        assert @creative.trigger_loop_enabled?
        assert_equal @creative, @creative.trigger_loop_context
      end

      test "allows instructions without a goal and a custom limit" do
        comment = command("/keep --max 3")
        assert_nil KeepCommand.new(comment: comment, user: @user).call
        assert_equal "", comment.keep_loop_options["goal"]
        assert_equal 3, comment.keep_loop_options["max_iterations"]
        assert_includes comment.content, I18n.t("collavre.trigger_loop.instructions")
      end

      test "rejects invalid limits without changing loop state" do
        %w[0 -1 abc 1.5].each do |limit|
          comment = command("/keep --max #{limit}")
          assert_equal I18n.t("collavre.comments.keep_command.invalid_max"),
                       KeepCommand.new(comment: comment, user: @user).call
          assert_nil comment.keep_loop_options
        end
      end

      test "does not handle other commands" do
        comment = command("/keeper finish")
        assert_nil KeepCommand.new(comment: comment, user: @user).call
        assert_nil comment.keep_loop_options
      end

      test "does not persist a loop when comment validation fails" do
        comment = command("/keep finish")
        KeepCommand.new(comment: comment, user: @user).call
        comment.content = ""
        assert_not comment.save
        assert_nil @creative.reload.data&.dig("trigger", "loop")
      end

      test "requires write permission" do
        comment = command("/keep finish")
        @creative.stub(:has_permission?, false) do
          assert_equal I18n.t("collavre.comments.keep_command.not_authorized"),
                       KeepCommand.new(comment: comment, user: @user).call
        end
        assert_nil comment.keep_loop_options
      end

      test "selects a mentioned agent without pinning the topic" do
        agent = User.create!(email: "keep-agent@example.com", name: "KeepAgent", password: "password123",
                             llm_vendor: "openai", llm_model: "gpt-4", searchable: true)
        comment = command("/keep finish @KeepAgent: --max 2")
        assert_nil KeepCommand.new(comment: comment, user: @user).call
        assert_equal agent.id, comment.keep_loop_options["agent_id"]
        assert_equal "finish", comment.keep_loop_options["goal"]
        assert_match(/\A@KeepAgent:/, comment.content)
        assert_nil @topic.reload.primary_agent_id
      end

      test "assigns Main when no topic was supplied" do
        comment = command("/keep finish")
        comment.topic = nil
        KeepCommand.new(comment: comment, user: @user).call
        assert_equal @topic, comment.topic
      end

      test "human response resumes a blocked keep loop using normal routing" do
        @creative.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
          @topic.id, source: "keep", state: "awaiting_user"
        ) } })
        response = command("You can proceed")
        response.save!
        response.send(:resume_trigger_loop_if_awaiting)
        assert_equal "running", @creative.reload.data.dig("trigger", "loop", "state")
        refute_match(/@/, @creative.comments.order(:id).last.content)
      end

      test "keep appears in command menu in both languages" do
        %i[en ko].each do |locale|
          I18n.with_locale(locale) do
            item = CommandMenuService.new(user: @user).items.find { |entry| entry[:name] == "keep" }
            assert_equal "/keep", item[:label]
            assert_equal I18n.t("collavre.comments.keep_command.description"), item[:description]
          end
        end
      end

      test "a new keep excludes tasks dispatched by an earlier command" do
        comment = command("/keep new goal")
        KeepCommand.new(comment: comment, user: @user).call
        comment.skip_dispatch = true
        comment.save!
        old_task = Task.new(trigger_event_payload: { "comment" => { "id" => comment.id - 1 } })
        current_task = Task.new(trigger_event_payload: { "comment" => { "id" => comment.id } })
        refute @creative.reload.trigger_loop_task?(old_task)
        assert @creative.trigger_loop_task?(current_task)
      end

      test "rejects private goals instead of exposing them through loop metadata" do
        comment = command("/keep confidential work")
        comment.private = true
        assert_equal I18n.t("collavre.comments.keep_command.private_not_supported"),
                     KeepCommand.new(comment: comment, user: @user).call
        assert_nil comment.keep_loop_options
      end

      test "command processor recognizes keep" do
        comment = command("/keep finish")
        assert_nil CommandProcessor.new(comment: comment, user: @user).call
        assert_equal "finish", comment.keep_loop_options["goal"]
      end

      test "topic movement rolls back creation and loop initialization" do
        comment = command("/keep finish")
        KeepCommand.new(comment: comment, user: @user).call
        Comments::TopicMutation.stub(:call, false) do
          assert_not comment.save
        end
        assert_nil @creative.reload.data&.dig("trigger", "loop")
      end

      test "blocked keep resumes with the explicitly selected agent" do
        agent = users(:ai_bot)
        @creative.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
          @topic.id, source: "keep", state: "awaiting_user", agent_id: agent.id
        ) } })
        SystemEvents::Dispatcher.stub(:dispatch, []) do
          command("Proceed").send(:resume_trigger_loop_if_awaiting)
        end
        assert_match(/@#{Regexp.escape(agent.name)}:/, @creative.comments.order(:id).last.content)
      end

      private

      def command(content)
        @creative.comments.build(content: content, user: @user, topic: @topic)
      end
    end
  end
end
