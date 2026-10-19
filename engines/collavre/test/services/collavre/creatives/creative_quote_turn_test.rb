require "test_helper"

module Collavre
  module Creatives
    class CreativeQuoteTurnTest < ActiveSupport::TestCase
      setup do
        @user = User.create!(name: "Doc Owner", email: "doc_quote_turn@example.com", password: "password123")
        @agent = users(:ai_bot)
        Current.user = @user
        @document = Creative.create!(description: "<p>Document</p>", user: @user)
        @section = Creative.create!(description: "<p>Section text to revise</p>", user: @user, parent: @document)
        CreativeShare.create!(creative: @document, user: @agent, shared_by: @user, permission: :write)
        @topic = Topic.create!(creative: @document, user: @user, name: "Doc chat")
      end

      teardown do
        Current.reset
      end

      test "a review turn forces a draft even under the auto write policy" do
        task = quote_task(review_type: nil)

        result = agent_turn(task) do
          Tools::CreativeUpdateService.new.call(id: @section.id, description: "Revised section")
        end

        assert result[:pending_review]
        assert_equal "<p>Section text to revise</p>", @section.reload.description
        draft = CreativeChangeSet.find(result[:change_set_id])
        assert_equal "draft", draft.status
        assert_equal task.id, draft.task_id
      end

      test "a question turn refuses every write" do
        task = quote_task(review_type: :question)

        result = agent_turn(task) do
          Tools::CreativeUpdateService.new.call(id: @section.id, description: "Should not land")
        end

        assert_equal false, result[:success]
        assert_equal I18n.t("collavre.comments.creative_quote.question_read_only"), result[:error]
        assert_equal "<p>Section text to revise</p>", @section.reload.description
        assert_equal 0, CreativeChangeSet.where(task_id: task.id).count
      end

      test "an ordinary agent turn keeps the creative's own policy" do
        comment = Comment.create!(creative: @document, topic: @topic, user: @user, content: "plain request")
        task = Task.create!(agent: @agent, creative: @document, topic_id: @topic.id, name: "Plain",
                            status: "running", trigger_comment_id: comment.id)

        assert_nil CreativeQuoteTurn.from_task(task)
        result = agent_turn(task) do
          Tools::CreativeUpdateService.new.call(id: @section.id, description: "Applied directly")
        end

        assert result[:success]
        assert_nil result[:pending_review]
      end

      test "a delegated MCP agent is resolved through its active quote task" do
        task = quote_task(review_type: nil, status: "delegated")

        result = Current.set(user: @agent, mcp_request: true) do
          Tools::CreativeUpdateService.new.call(id: @section.id, description: "MCP revision")
        end

        assert result[:pending_review]
        assert_equal task.id, CreativeChangeSet.find(result[:change_set_id]).task_id
      end

      test "a question among a delegated MCP agent's tasks wins" do
        quote_task(review_type: nil, status: "delegated")
        quote_task(review_type: :question, status: "running")

        turn = Current.set(user: @agent, mcp_request: true) { CreativeQuoteTurn.current }

        assert turn.question?
        assert_equal @section, turn.quoted_creative
      end

      test "an MCP request from a person or without quote tasks has no quote turn" do
        assert_nil Current.set(user: @user, mcp_request: true) { CreativeQuoteTurn.current }
        assert_nil Current.set(user: @agent, mcp_request: true) { CreativeQuoteTurn.current }
        assert_nil Current.set(user: @agent) { CreativeQuoteTurn.current }
      end

      private

      def quote_task(review_type:, status: "running")
        comment = Comment.create!(creative: @document, topic: @topic, user: @user, content: "> Section text\n\nfix it",
                                  quoted_creative: @section, quoted_text: "Section text", review_type: review_type,
                                  skip_dispatch: true)
        Task.create!(agent: @agent, creative: @document, topic_id: @topic.id, name: "Quote", status: status,
                     trigger_comment_id: comment.id)
      end

      def agent_turn(task, &block)
        Current.set(user: @agent, agent_turn: { user: @user, task: task }, &block)
      end
    end
  end
end
