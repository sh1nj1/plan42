require "test_helper"

module Collavre
  module Comments
    class KeepCommandTest < ActiveSupport::TestCase
      setup do
        @creative = creatives(:tshirt)
        @user = users(:one)
        @topic = @creative.main_topic
      end

      test "selected agent exclusively receives the initial turn while goal mentions stay intact" do
        agent = users(:ai_bot)
        other = agent.dup
        other.email = "keep-other@example.com"
        other.name = "KeepOther"
        other.save!
        [ agent, other ].each do |user|
          CreativeShare.find_or_create_by!(creative: @creative, user: user).update!(permission: :feedback)
          CreativeSharesCache.find_or_create_by!(creative: @creative, user: user).update!(permission: :feedback)
        end
        comment = command("/keep @#{agent.name}: compare with @#{other.name}: output")
        KeepCommand.new(comment: comment, user: @user).call
        comment.skip_dispatch = true
        comment.save!
        payload = Comment.find(comment.id).dispatch_payload
        context = SystemEvents::ContextBuilder.new(payload).build
        assert_includes payload[:comment][:content], "@#{other.name}: output"
        assert_equal [ agent ], Orchestration::Matcher.new(context).match
        @creative.update!(data: {})
        assert_equal [ agent, other ].map(&:id).sort,
                     Orchestration::Matcher.new(SystemEvents::ContextBuilder.new(comment.reload.dispatch_payload).build).match.map(&:id).sort
      end

      test "goal separator preserves reserved leading tokens without selecting an agent" do
        [ "@#{users(:ai_bot).name}: investigate", "--max 1 investigate", "-- investigate", "--" ].each do |goal|
          comment = command("/keep -- #{goal}")
          assert_nil KeepCommand.new(comment: comment, user: @user).call
          assert_equal goal, comment.keep_loop_options["goal"]
          assert_nil comment.keep_loop_options["agent_id"]
          assert_equal 10, comment.keep_loop_options["max_iterations"]
        end
      end

      test "separator after explicit options preserves goal and routing" do
        agent = users(:ai_bot)
        CreativeShare.find_or_create_by!(creative: @creative, user: agent).update!(permission: :feedback)
        comment = command("/keep --max 5 @#{agent.name}: -- @Other: investigate")
        assert_nil KeepCommand.new(comment: comment, user: @user).call
        assert_equal "@Other: investigate", comment.keep_loop_options["goal"]
        assert_equal agent.id, comment.keep_loop_options["agent_id"]
        assert_equal 5, comment.keep_loop_options["max_iterations"]
      end

      test "no-agent notice is created outside the creative lock block" do
        comment = command("/keep finish")
        KeepCommand.new(comment: comment, user: @user).call
        comment.skip_dispatch = true
        comment.save!
        locked = false
        lock = lambda do |&block|
          locked = true
          block.call
        ensure
          locked = false
        end
        association = @creative.comments
        create = association.method(:create!)
        notice = lambda do |**attributes|
          assert_not locked
          assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
          create.call(**attributes)
        end
        @creative.stub(:with_lock, lock) do
          @creative.stub(:comments, association) do
            association.stub(:create!, notice) { comment.send(:reconcile_loop_dispatch, []) }
          end
        end
      end

      test "initial dispatch without a matched agent awaits user instead of hanging" do
        comment = command("/keep finish")
        KeepCommand.new(comment: comment, user: @user).call
        SystemEvents::Dispatcher.stub(:dispatch, []) { comment.save! }
        assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
        assert_equal I18n.t("collavre.comments.keep_command.no_agent"), @creative.comments.order(:id).last.content
      end

      test "initial dispatch failure leaves the committed keep recoverable and preserves the exception" do
        comment = command("/keep finish")
        KeepCommand.new(comment: comment, user: @user).call
        failure = RuntimeError.new("orchestration unavailable")
        SystemEvents::Dispatcher.stub(:dispatch, ->(*) { raise failure }) do
          assert_same failure, assert_raises(RuntimeError) { comment.save! }
        end
        assert Comment.exists?(comment.id)
        assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
        assert_equal comment.id, @creative.data.dig("trigger", "loop", "current_comment_id")
        assert_empty Task.where(creative_id: @creative.id)
        assert_nil KeepCommand.new(comment: command("/keep retry"), user: @user).call
      end

      test "dispatch failure does not overwrite a concurrent pause or replacement loop" do
        comment = command("/keep finish")
        KeepCommand.new(comment: comment, user: @user).call
        comment.skip_dispatch = true
        comment.save!
        original = @creative.reload.data.dig("trigger", "loop")
        [ { "state" => "paused" }, { "current_comment_id" => comment.id + 1 } ].each do |changes|
          config = original.merge(changes)
          @creative.update!(data: { "trigger" => { "loop" => config } })
          comment.skip_dispatch = false
          SystemEvents::Dispatcher.stub(:dispatch, ->(*) { raise "dispatch failed" }) do
            assert_raises(RuntimeError) { comment.send(:dispatch_to_orchestration) }
          end
          assert_equal config, @creative.reload.data.dig("trigger", "loop")
        end
      end

      test "rejects keep in the Inbox System topic where dispatch is suppressed" do
        @creative = Creative.create!(description: "Inbox", data: { "kind" => "inbox" }, user: @user)
        @topic = @creative.system_topic
        comment = command("/keep finish")
        assert_equal I18n.t("collavre.comments.keep_command.no_agent"), KeepCommand.new(comment: comment, user: @user).call
        assert_nil comment.keep_loop_options
      end

      test "Claude channel agent with feedback cannot strand keep in ordinary Inbox" do
        @creative = Creative.create!(description: "Inbox", data: { "kind" => "inbox" }, user: @user)
        @topic = @creative.main_topic
        agent = users(:ai_bot)
        agent.update!(llm_model: "claude-code")
        CreativeShare.create!(creative: @creative, user: agent, permission: :feedback)
        comment = command("/keep @#{agent.name}: finish")
        assert_nil KeepCommand.new(comment: comment, user: @user).call
        comment.save!
        assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
        assert_empty Task.where(creative_id: @creative.id)
      end

      test "rejected initial agent enqueue leaves the committed keep recoverable" do
        agent = users(:ai_bot)
        CreativeShare.create!(creative: @creative, user: agent, permission: :feedback)
        comment = command("/keep @#{agent.name}: finish")
        assert_nil KeepCommand.new(comment: comment, user: @user).call
        AiAgentJob.stub(:perform_later, false) do
          assert_raises(ActiveJob::EnqueueError) { comment.save! }
        end
        assert Comment.exists?(comment.id)
        assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
        assert_empty Task.where(creative_id: @creative.id)
      end

      test "initial dispatch with an agent stays running" do
        comment = command("/keep finish")
        KeepCommand.new(comment: comment, user: @user).call
        SystemEvents::Dispatcher.stub(:dispatch, [ users(:ai_bot) ]) { comment.save! }
        assert_equal "running", @creative.reload.data.dig("trigger", "loop", "state")
        assert_equal comment.id, @creative.data.dig("trigger", "loop", "current_comment_id")
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
        %w[0 -1 abc 1.5 1001 100000].each do |limit|
          comment = command("/keep --max #{limit}")
          assert_equal I18n.t("collavre.comments.keep_command.invalid_max"),
                       KeepCommand.new(comment: comment, user: @user).call
          assert_nil comment.keep_loop_options
        end
      end

      test "accepts limits through the new maximum" do
        [ 1, 51, 1000 ].each do |limit|
          comment = command("/keep --max #{limit} finish")
          assert_nil KeepCommand.new(comment: comment, user: @user).call
          assert_equal limit, comment.keep_loop_options["max_iterations"]
        end
      end

      test "preserves max options inside the goal" do
        agent = User.create!(email: "max-keep@example.com", name: "MaxKeep", password: "password123",
                             llm_vendor: "openai", llm_model: "gpt-4", searchable: true)
        CreativeShare.create!(creative: @creative, user: agent, permission: :feedback)
        [ "document the --max flag", "document --max 5", "@#{agent.name}: document --max 5" ].each do |goal|
          comment = command("/keep #{goal}")
          assert_nil KeepCommand.new(comment: comment, user: @user).call
          assert_equal 10, comment.keep_loop_options["max_iterations"]
          assert_equal goal.sub(/\A@.*?: /, ""), comment.keep_loop_options["goal"]
        end
      end

      test "rejects a leading max option without a value" do
        comment = command("/keep --max")
        assert_equal I18n.t("collavre.comments.keep_command.invalid_max"),
                     KeepCommand.new(comment: comment, user: @user).call
        assert_nil comment.keep_loop_options
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
        CreativeShare.create!(creative: @creative, user: agent, permission: :feedback)
        comment = command("/keep --max 2 @KeepAgent: finish")
        assert_nil KeepCommand.new(comment: comment, user: @user).call
        assert_equal agent.id, comment.keep_loop_options["agent_id"]
        assert_equal "finish", comment.keep_loop_options["goal"]
        assert_match(/\A@KeepAgent:/, comment.content)
        assert_nil @topic.reload.primary_agent_id
      end

      test "only the leading agent mention selects routing and other mentions remain in the goal" do
        first = users(:ai_bot)
        second = User.create!(email: "other-keep@example.com", name: "OtherKeep", password: "password123",
                              llm_vendor: "openai", llm_model: "gpt-4", searchable: true)
        CreativeShare.create!(creative: @creative, user: second, permission: :feedback)
        comment = command("/keep @#{second.name}: compare with @#{first.name}: output")
        KeepCommand.new(comment: comment, user: @user).call
        assert_equal second.id, comment.keep_loop_options["agent_id"]
        assert_equal "compare with @#{first.name}: output", comment.keep_loop_options["goal"]
      end

      test "mentions inside a goal do not select an agent or change the goal" do
        goal = "compare with @#{users(:ai_bot).name}: output"
        comment = command("/keep #{goal}")
        KeepCommand.new(comment: comment, user: @user).call
        assert_nil comment.keep_loop_options["agent_id"]
        assert_equal goal, comment.keep_loop_options["goal"]
      end

      test "rejects an active loop under lock even when it started after command parsing" do
        %w[keep drop].each do |source|
          %w[running pending_verification].each do |state|
            comment = command("/keep replacement")
            KeepCommand.new(comment: comment, user: @user).call
            existing = TriggerLoopConfig.build(@topic.id, source: source, state: state, goal: "original")
            Creative.find(@creative.id).update!(data: { "trigger" => { "loop" => existing } })
            comment.skip_dispatch = true
            assert_no_difference -> { @creative.comments.count } do
              assert_not comment.save
            end
            assert_includes comment.errors[:base], I18n.t("collavre.comments.keep_command.already_running")
            assert_equal existing, @creative.reload.data.dig("trigger", "loop")
          end
        end
      end

      test "rejects a selected agent without response permission" do
        agent = User.create!(email: "denied-keep@example.com", name: "DeniedKeep", password: "password123",
                             llm_vendor: "openai", llm_model: "gpt-4", searchable: true)
        comment = command("/keep @#{agent.name}: finish")
        assert_equal I18n.t("collavre.comments.keep_command.agent_not_authorized"),
                     KeepCommand.new(comment: comment, user: @user).call
        assert_nil comment.keep_loop_options
      end

      test "does not execute commands embedded at the beginning of the goal" do
        comment = command("/keep /compress summarize this")
        handler = Object.new
        handler.define_singleton_method(:call) { flunk "Subsequent handler must not run" }
        processor = CommandProcessor.new(comment: comment, user: @user)
        processor.stub(:command_handlers, [ KeepCommand.new(comment: comment, user: @user), handler ]) do
          assert_nil processor.call
        end
        assert_equal "/compress summarize this", comment.keep_loop_options["goal"]
        refute comment.skip_dispatch
      end

      test "assigns Main when no topic was supplied" do
        comment = command("/keep finish")
        comment.topic = nil
        KeepCommand.new(comment: comment, user: @user).call
        assert_equal @topic, comment.topic
      end

      test "ambient keep replies dispatch only one synthetic continuation" do
        @creative.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
          @topic.id, source: "keep", state: "awaiting_user"
        ) } })
        response = command("You can proceed")
        dispatched = []
        SystemEvents::Dispatcher.stub(:dispatch, lambda { |_event, payload, **_options|
          dispatched << payload
          [ users(:ai_bot) ]
        }) do
          assert_difference -> { @creative.comments.count }, 2 do
            response.save!
          end
        end
        resume = @creative.comments.order(:id).last
        assert_equal [ resume.id ], dispatched.map { |payload| payload.dig(:comment, :id) }
        assert_equal "running", @creative.reload.data.dig("trigger", "loop", "state")
        assert_equal resume.id, @creative.data.dig("trigger", "loop", "current_comment_id")
        refute_match(/@/, resume.content)
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
        current_task = Task.new(trigger_event_payload: comment.dispatch_payload.deep_stringify_keys)
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

      test "human reply does not reroute a blocked keep with a missing agent" do
        @creative.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
          @topic.id, source: "keep", state: "awaiting_user", agent_id: -1
        ) } })
        assert_no_difference -> { @creative.comments.count } do
          command("Proceed").send(:resume_trigger_loop_if_awaiting)
        end
        assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
      end

      test "blocked keep resumes with the explicitly selected agent" do
        agent = users(:ai_bot)
        CreativeShare.create!(creative: @creative, user: agent, permission: :feedback)
        @creative.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
          @topic.id, source: "keep", state: "awaiting_user", agent_id: agent.id
        ) } })
        SystemEvents::Dispatcher.stub(:dispatch, [ agent ]) do
          command("Proceed").send(:resume_trigger_loop_if_awaiting)
        end
        assert_match(/@#{Regexp.escape(agent.name)}:/, @creative.comments.order(:id).last.content)
      end

      test "blocked replies dispatch only the selected agent resume turn" do
        agent = users(:ai_bot)
        CreativeShare.create!(creative: @creative, user: agent, permission: :feedback)
        other = agent.dup
        other.email = "keep-reply-other@example.com"
        other.name = "KeepReplyOther"
        other.save!
        CreativeShare.create!(creative: @creative, user: other, permission: :feedback)
        [ "Proceed", "Compare with @#{other.name}: output" ].each do |content|
          @creative.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
            @topic.id, source: "keep", state: "awaiting_user", agent_id: agent.id
          ) } })
          dispatched = []
          dispatch = lambda do |_event, payload, **_options|
            dispatched << payload
            [ agent ]
          end
          response = command(content)
          SystemEvents::Dispatcher.stub(:dispatch, dispatch) do
            assert_difference -> { @creative.comments.count }, 2 do
              response.save!
            end
          end
          assert_equal 1, dispatched.size
          resume = @creative.comments.order(:id).last
          assert_equal resume.id, dispatched.first.dig(:comment, :id)
          assert_equal [ { id: agent.id } ], dispatched.first.dig(:chat, :mentioned_users)
          assert_equal "running", @creative.reload.data.dig("trigger", "loop", "state")
          assert_equal resume.id, @creative.data.dig("trigger", "loop", "current_comment_id")
          assert_equal content, response.reload.content
        end
      end

      test "private replies do not resume a blocked keep loop" do
        agent = users(:ai_bot)
        CreativeShare.create!(creative: @creative, user: agent, permission: :feedback)
        @creative.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
          @topic.id, source: "keep", state: "awaiting_user", agent_id: agent.id
        ) } })
        previous = @creative.data.deep_dup
        SystemEvents::Dispatcher.stub(:dispatch, ->(*) { flunk "Private reply must not dispatch" }) do
          assert_difference -> { @creative.comments.count }, 1 do
            command("Confidential input").tap { |comment| comment.private = true }.save!
          end
        end
        assert_equal previous, @creative.reload.data
      end

      test "rejects unresolved and non AI leading selectors without starting a loop" do
        hidden = User.create!(email: "hidden-keep@example.com", name: "HiddenKeep", password: "password123",
                              llm_vendor: "openai", llm_model: "gpt-4", searchable: false)
        [ "TypoMissing", users(:two).name, hidden.name ].each do |name|
          comment = command("/keep --max 2 @#{name}: finish")
          assert_equal I18n.t("collavre.comments.keep_command.agent_not_authorized"),
                       KeepCommand.new(comment: comment, user: @user).call
          assert_nil comment.keep_loop_options
          assert_equal "/keep --max 2 @#{name}: finish", comment.content
        end
      end

      test "saving a blocked reply never dispatches to ambient agents when selection is unavailable" do
        agent = users(:ai_bot)
        [ -1, agent.id ].each do |agent_id|
          @creative.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
            @topic.id, source: "keep", state: "awaiting_user", agent_id: agent_id
          ) } })
          response = command("Proceed")
          SystemEvents::Dispatcher.stub(:dispatch, ->(*) { flunk "Unavailable keep must not dispatch" }) do
            assert_difference -> { @creative.comments.count }, 1 do
              response.save!
            end
          end
          assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
        end
      end

      test "unavailable keep does not suppress replies in other topics" do
        other = @creative.topics.create!(name: "Other", user: @user)
        @creative.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
          @topic.id, source: "keep", state: "awaiting_user", agent_id: -1
        ) } })
        dispatched = false
        SystemEvents::Dispatcher.stub(:dispatch, ->(*) { dispatched = true; [] }) do
          command("Other work").tap { |comment| comment.topic = other }.save!
        end
        assert dispatched
      end

      test "keep detaches quoted review metadata before routing" do
        agent = users(:ai_bot)
        CreativeShare.create!(creative: @creative, user: agent, permission: :feedback)
        author = agent.dup
        author.email = "keep-review-author@example.com"
        author.name = "KeepReviewAuthor"
        author.save!
        CreativeShare.create!(creative: @creative, user: author, permission: :feedback)
        quoted = @creative.comments.create!(content: "Original", user: author, topic: @topic, skip_dispatch: true)
        comment = command("/keep @#{agent.name}: finish")
        comment.quoted_comment = quoted
        comment.review_type = :review
        assert_nil KeepCommand.new(comment: comment, user: @user).call
        assert_nil comment.quoted_comment_id
        assert_nil comment.review_type
        comment.skip_dispatch = true
        comment.save!
        payload = comment.reload.dispatch_payload
        assert_equal [ agent ], Orchestration::Matcher.new(SystemEvents::ContextBuilder.new(payload).build).match
        assert_not comment.review_message?
        assert_equal "Original", quoted.reload.content
      end

      test "pause after reply transition prevents resume dispatch" do
        @creative.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
          @topic.id, source: "keep", state: "awaiting_user"
        ) } })
        response = command("Proceed")
        original = response.method(:post_loop_resume)
        pause = lambda do |*args|
          @creative.with_lock do
            data = @creative.data.deep_dup
            data["trigger"]["loop"]["state"] = "paused"
            @creative.update!(data: data)
          end
          original.call(*args)
        end
        SystemEvents::Dispatcher.stub(:dispatch, ->(*) { flunk "Paused reply must not dispatch" }) do
          response.stub(:post_loop_resume, pause) do
            assert_no_difference -> { @creative.comments.count } do
              response.send(:resume_trigger_loop_if_awaiting)
            end
          end
        end
        assert_equal "paused", @creative.reload.data.dig("trigger", "loop", "state")
      end

      test "reply resume rejects changed control version even after running is restored" do
        @creative.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
          @topic.id, source: "keep", state: "awaiting_user"
        ) } })
        response = command("Proceed")
        original = response.method(:post_loop_resume)
        change_version = lambda do |*args|
          @creative.with_lock do
            data = @creative.data.deep_dup
            config = data["trigger"]["loop"]
            config["control_version"] = config.fetch("control_version", 0) + 1
            @creative.update!(data: data)
          end
          original.call(*args)
        end
        SystemEvents::Dispatcher.stub(:dispatch, ->(*) { flunk "Stale reply must not dispatch" }) do
          response.stub(:post_loop_resume, change_version) do
            assert_no_difference -> { @creative.comments.count } do
              response.send(:resume_trigger_loop_if_awaiting)
            end
          end
        end
        assert_equal "running", @creative.reload.data.dig("trigger", "loop", "state")
      end

      test "agent permission loss between reply transition and dispatch restores awaiting user" do
        agent = users(:ai_bot)
        CreativeShare.create!(creative: @creative, user: agent, permission: :feedback)
        @creative.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
          @topic.id, source: "keep", state: "awaiting_user", agent_id: agent.id
        ) } })
        response = command("Proceed")
        original = response.method(:post_loop_resume)
        revoke = lambda do |*args|
          CreativeShare.where(creative: @creative, user: agent).destroy_all
          CreativeSharesCache.where(creative: @creative, user: agent).delete_all
          original.call(*args)
        end
        SystemEvents::Dispatcher.stub(:dispatch, ->(*) { flunk "Unavailable agent must not dispatch" }) do
          response.stub(:post_loop_resume, revoke) do
            assert_no_difference -> { @creative.comments.count } do
              response.send(:resume_trigger_loop_if_awaiting)
            end
          end
        end
        assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
      end

      test "blocked reply routing reads persisted state in both directions" do
        agent = users(:ai_bot)
        %w[running awaiting_user].each do |cached_state|
          @creative.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
            @topic.id, source: "keep", state: cached_state, agent_id: agent.id
          ) } })
          response = command("Proceed")
          persisted_state = cached_state == "running" ? "awaiting_user" : "running"
          data = @creative.data.deep_merge("trigger" => { "loop" => { "state" => persisted_state } })
          Creative.where(id: @creative.id).update_all(data: data)
          assert_equal persisted_state == "awaiting_user", !!response.send(:blocked_keep_reply?)
        end
      end

      test "ordinary dispatched reply cannot also resume a newly blocked ambient keep" do
        @creative.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
          @topic.id, source: "keep", state: "running"
        ) } })
        response = command("Proceed")
        refute response.send(:blocked_keep_reply?)
        data = @creative.data.deep_merge("trigger" => { "loop" => { "state" => "awaiting_user" } })
        Creative.where(id: @creative.id).update_all(data: data)
        SystemEvents::Dispatcher.stub(:dispatch, ->(*) { flunk "Already routed reply must not resume" }) do
          assert_no_difference -> { @creative.comments.count } do
            response.send(:resume_trigger_loop_if_awaiting)
          end
        end
        assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
      end

      test "reply resume explicitly dispatches while guarded instead of after commit" do
        @creative.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
          @topic.id, source: "keep", state: "awaiting_user"
        ) } })
        response = command("Proceed")
        dispatched = []
        guard_depth = 0
        lock = @creative.method(:with_lock)
        @creative.define_singleton_method(:with_lock) do |*args, &block|
          lock.call(*args) do
            guard_depth += 1
            begin
              block.call
            ensure
              guard_depth -= 1
            end
          end
        end
        created = nil
        original = response.method(:create_loop_resume)
        response.define_singleton_method(:create_loop_resume) do |*args|
          created = original.call(*args)
        end
        SystemEvents::Dispatcher.stub(:dispatch, lambda { |_event, payload, **_options|
          dispatched << payload
          assert_operator guard_depth, :>, 0, "Resume must dispatch before releasing the creative lock"
          assert @creative.comments.find(payload.dig(:comment, :id)).persisted?
          [ users(:ai_bot) ]
        }) do
          response.send(:resume_trigger_loop_if_awaiting)
        end
        assert_equal 1, dispatched.size
        assert created.skip_dispatch, "Continuation must suppress its after-commit dispatch"
      end

      test "deleting the current keep turn clears only the loop and permits a new keep" do
        comment = command("/keep finish")
        KeepCommand.new(comment: comment, user: @user).call
        comment.skip_dispatch = true
        comment.save!
        @creative.update!(data: @creative.data.deep_merge("trigger" => { "custom" => "preserved" }))
        comment.destroy!
        assert_nil @creative.reload.data.dig("trigger", "loop")
        assert_equal "preserved", @creative.data.dig("trigger", "custom")
        replacement = command("/keep new goal")
        assert_nil KeepCommand.new(comment: replacement, user: @user).call
      end

      %w[queued running].each do |status|
        test "deleting a #{status} keep continuation clears its loop" do
          initial = command("/keep finish")
          KeepCommand.new(comment: initial, user: @user).call
          initial.skip_dispatch = true
          initial.save!
          continuation = @creative.comments.create!(content: "continue", topic: @topic, user: @user,
                                                    loop_continuation: true, skip_dispatch: true)
          task = Task.create!(name: "Keep turn", status: status, agent: users(:ai_bot), creative: @creative,
                              topic_id: @topic.id, trigger_event_payload: { "comment" => { "id" => continuation.id } })
          initial.destroy!
          assert_equal continuation.id, @creative.reload.data.dig("trigger", "loop", "current_comment_id")
          continuation.destroy!
          assert_nil @creative.reload.data.dig("trigger", "loop")
          continuation.send(:cancel_pending_tasks)
          assert task.reload.cancelled?
        end
      end

      test "deleting an unrelated comment or a drop turn preserves the loop" do
        comment = command("ordinary")
        comment.skip_dispatch = true
        comment.save!
        [ { "source" => "keep", "current_comment_id" => comment.id + 1 },
          { "current_comment_id" => comment.id } ].each do |config|
          @creative.update!(data: { "trigger" => { "loop" => config } })
          Comment.transaction(requires_new: true) do
            comment.destroy!
            assert_equal config, @creative.reload.data.dig("trigger", "loop")
            raise ActiveRecord::Rollback
          end
          comment = Comment.find(comment.id)
          assert_equal config, @creative.reload.data.dig("trigger", "loop")
        end
      end

      private

      def command(content)
        @creative.comments.build(content: content, user: @user, topic: @topic)
      end
    end
  end
end
