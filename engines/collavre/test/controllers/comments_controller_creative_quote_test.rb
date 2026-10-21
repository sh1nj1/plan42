require "test_helper"

class CommentsControllerCreativeQuoteTest < ActionDispatch::IntegrationTest
  setup do
    Collavre::Kollavy.seed!
    @user = users(:one)
    @agent = users(:ai_bot)
    @user.update!(email_verified_at: Time.current)
    post session_path, params: { email: @user.email, password: "password" }
    @document = Collavre::Creative.create!(description: "<p>Document</p>", user: @user)
    @section = Collavre::Creative.create!(description: "<p>Section text to revise</p>", user: @user, parent: @document)
    @topic = Collavre::Topic.create!(creative: @document, user: @user, name: "Doc chat")
  end

  test "a document question quotes the creative and links back to it" do
    assert_difference -> { Collavre::Comment.count }, 1 do
      post creative_comments_path(@document), params: { comment: {
        content: "> ❓ Section text\n\nWhy?", topic_id: @topic.id, review_type: "question",
        quoted_creative_id: @section.id, quoted_text: "Section text"
      } }
    end

    assert_response :created
    comment = Collavre::Comment.order(:id).last
    assert_equal @section, comment.quoted_creative
    assert comment.creative_question_message?
    assert_select "a.comment-creative-quote-source[data-creative-quote-source-id=?]", @section.id.to_s
    assert_select ".comment-quoted-block", count: 0
  end

  test "a creative the sender cannot read cannot be quoted" do
    hidden = Collavre::Creative.create!(description: "<p>Secret</p>", user: users(:two))

    assert_no_difference -> { Collavre::Comment.count } do
      post creative_comments_path(@document), params: { comment: {
        content: "> Secret", topic_id: @topic.id, quoted_creative_id: hidden.id, quoted_text: "Secret"
      } }
    end

    assert_response :forbidden
    assert_equal I18n.t("collavre.comments.creative_quote.not_readable"), JSON.parse(response.body)["error"]
  end

  test "a message cannot quote a comment and a creative at once" do
    quoted = Collavre::Comment.create!(creative: @document, topic: @topic, user: @agent, content: "Agent text",
                                       skip_dispatch: true)

    post creative_comments_path(@document), params: { comment: {
      content: "> Agent text", topic_id: @topic.id, quoted_comment_id: quoted.id, quoted_creative_id: @section.id
    } }

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["errors"], I18n.t("collavre.comments.creative_quote.single_target")
  end

  test "the agent's reply carries the proposed change and a rejection leaves a notice" do
    task, reply = proposed_review

    get creative_comments_path(@document), params: { topic_id: @topic.id }

    assert_response :success
    url = creative_change_set_path(@document, Collavre::CreativeChangeSet.find_by!(task_id: task.id))
    assert_select "#comment_#{reply.id} .creative-quote-review details[open][data-creative-history-detail-url-value=?]", url
    assert_select ".creative-quote-review-warning", count: 0

    change_set = Collavre::CreativeChangeSet.find_by!(task_id: task.id)
    assert_difference -> { Collavre::Comment.where(topic: @topic, user_id: nil).count }, 1 do
      post creative_apply_change_set_path(@document, change_set), params: { mode: "reject" }, as: :json
    end

    assert_response :success
    assert_equal "rejected", change_set.reload.status
    notice = Collavre::Comment.where(topic: @topic, user_id: nil).order(:id).last
    assert_includes notice.content, @section.creative_snippet
    assert_equal "<p>Section text to revise</p>", @section.reload.description
  end

  test "approving the proposed change applies it" do
    task, = proposed_review
    change_set = Collavre::CreativeChangeSet.find_by!(task_id: task.id)

    assert_no_difference -> { Collavre::Comment.where(topic: @topic, user_id: nil).count } do
      post creative_apply_change_set_path(@document, change_set), params: { mode: "approve" }, as: :json
    end

    assert_response :success
    assert_equal "applied", change_set.reload.status
    assert_includes @section.reload.description, "Revised section"
  end

  private

  def proposed_review
    Collavre::CreativeShare.create!(creative: @document, user: @agent, shared_by: @user, permission: :write)
    trigger = Collavre::Comment.create!(creative: @document, topic: @topic, user: @user, content: "> Section\n\nRevise",
                                        quoted_creative: @section, quoted_text: "Section", skip_dispatch: true)
    task = Collavre::Task.create!(agent: @agent, creative: @document, topic_id: @topic.id, name: "Review",
                                  status: "running", trigger_comment_id: trigger.id)
    result = Collavre::Current.set(user: @agent, agent_turn: { user: @user, task: task }) do
      Collavre::Tools::CreativeUpdateService.new.call(id: @section.id, description: "Revised section")
    end
    assert result[:pending_review]
    reply = Collavre::Comment.create!(creative: @document, topic: @topic, user: @agent, content: "Proposed a revision",
                                      task: task, skip_dispatch: true)
    [ task, reply ]
  end
end
