require "test_helper"
require "json"

class CommentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
    @user.update!(email_verified_at: Time.current)
    post session_path, params: { email: @user.email, password: "password" }
  end

  private

  # Helper to ensure users(:two) has at least read access to the creative
  def grant_read_access_to_other_user(creative = @creative, user: users(:two), permission: :read)
    user.update!(email_verified_at: Time.current) unless user.email_verified_at?
    share = CreativeShare.find_by(creative: creative, user: user)
    if share
      share.update!(permission: permission) if share.permission.to_s < permission.to_s
    else
      CreativeShare.create!(creative: creative, user: user, shared_by: @user, permission: permission)
    end
  end

  public

  test "index renders version navigator only for comments with versions" do
    with_versions = @creative.comments.create!(content: "has versions", user: @user)
    Collavre::CommentVersion.create!(comment: with_versions, content: "v1", version_number: 1)
    Collavre::CommentVersion.create!(comment: with_versions, content: "v2", version_number: 2)
    without_versions = @creative.comments.create!(content: "no versions", user: @user)

    get creative_comments_path(@creative)
    assert_response :success

    assert_includes @response.body,
                    "data-comment-version-comment-id-value=\"#{with_versions.id}\"",
                    "expected version navigator for comment WITH versions"
    assert_not_includes @response.body,
                        "data-comment-version-comment-id-value=\"#{without_versions.id}\"",
                        "expected no version navigator for comment WITHOUT versions"
  end

  test "creating a public comment completes the matching onboarding chat practice" do
    @user.update!(onboarding_seeded_at: nil, onboarding_completed_at: nil)
    Creative.inbox_for(@user)
    guide = Collavre::Onboarding::Seeder.call(user: @user)
    card = guide.children.find { |creative| creative.onboarding_metadata["step_key"] == "creative_chat" }
    practice = card.children.sole

    post creative_comments_path(practice), params: {
      comment: { content: "My first message", topic_id: practice.main_topic.id, private: false }
    }

    assert_response :created
    assert_equal card.id.to_s, response.headers["X-Onboarding-Card-Id"]
    assert_equal guide.id.to_s, response.headers["X-Onboarding-Root-Id"]
    assert_equal "completed", card.reload.onboarding_metadata["status"]
    assert_in_delta 1.0, practice.reload.progress
  end

  test "records an onboarding mention before dispatching it to an agent" do
    @user.update!(onboarding_seeded_at: nil, onboarding_completed_at: nil)
    agent = users(:ai_bot)
    agent.update!(created_by_id: @user.id)
    Creative.inbox_for(@user)
    guide = Collavre::Onboarding::Seeder.call(user: @user)
    card = guide.children.find { |creative| creative.onboarding_metadata["step_key"] == "mention_agent" }
    practice = card.children.sole
    state_at_dispatch = nil

    dispatch = lambda do |event_name, context|
      next unless event_name == "comment_created" && context.dig(:comment, :user_id) == @user.id

      metadata = card.reload.onboarding_metadata
      state_at_dispatch = metadata.slice("invoked_agent_id", "response_status")
    end

    Collavre::SystemEvents::Dispatcher.stub(:dispatch, dispatch) do
      post creative_comments_path(practice), params: {
        comment: { content: "@#{agent.name}: help me", topic_id: practice.main_topic.id, private: false }
      }
    end

    assert_response :created
    assert_equal({ "invoked_agent_id" => agent.id, "response_status" => "waiting" }, state_at_dispatch)
  end

  test "convert markdown comment to sub creatives" do
    comment = @creative.comments.create!(content: "- First\n- Second", user: @user)
    assert_difference("Creative.count", 2) do
      assert_no_difference("Comment.count") do
        post convert_creative_comment_path(@creative, comment)
      end
    end
    assert_response :no_content
    @creative.reload
    titles = @creative.children.order(:id).map { |c| ActionController::Base.helpers.strip_tags(c.description).strip }
    assert_equal [ "First", "Second" ], titles

    system_comment = @creative.comments.order(:id).last
    assert_nil system_comment.user
    first_child = @creative.children.order(:id).first
    expected_title = ActionController::Base.helpers.strip_tags(first_child.description).strip
    expected_message = I18n.t(
      "collavre.comments.convert_system_message",
      title: expected_title,
      url: creative_path(first_child)
    )
    assert_equal expected_message, system_comment.content
  end

  test "creative admin can convert another user's comment" do
    other_user = users(:two)
    other_user.update!(email_verified_at: Time.current)

    shared_creative = nil
    perform_enqueued_jobs do
      shared_creative = Creative.create!(user: other_user, description: "Shared Creative", progress: 0.0)
      CreativeShare.create!(creative: shared_creative, user: @user, permission: :admin, shared_by: other_user)
    end

    comment = shared_creative.comments.create!(content: "- Shared task", user: other_user)
    creative_comment_count_before = shared_creative.comments.count

    assert_difference("Creative.count", 1) do
      perform_enqueued_jobs do
        post convert_creative_comment_path(shared_creative, comment)
      end
    end

    # Original comment destroyed, system comment added on the creative (net 0 on this creative)
    assert_equal creative_comment_count_before, shared_creative.comments.reload.count

    assert_response :no_content
    shared_creative.reload
    converted_child = shared_creative.children.order(:id).last
    assert_equal "Shared task", ActionController::Base.helpers.strip_tags(converted_child.description).strip
    assert_equal other_user.id, converted_child.user.id
  end

  test "converted creatives inherit parent creative user" do
    commenter = users(:two)
    commenter.update!(email_verified_at: Time.current)

    comment = @creative.comments.create!(content: "- Cross user task", user: commenter)
    creative_comment_count_before = @creative.comments.count

    assert_difference("Creative.count", 1) do
      post convert_creative_comment_path(@creative, comment)
    end

    # Original comment destroyed, system comment added (net 0 on this creative)
    assert_equal creative_comment_count_before, @creative.comments.reload.count

    assert_response :no_content
    child = @creative.children.order(:id).last
    assert_equal @creative.user.id, child.user.id
  end

  test "approver can execute comment action" do
    action_payload = {
      "action" => "update_creative",
      "attributes" => { "progress" => 0.9 }
    }

    comment = @creative.comments.create!(
      content: "Run action",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @user
    )

    post approve_creative_comment_path(@creative, comment)

    assert_response :success
    assert_includes @response.body, I18n.t("collavre.comments.approved_label")
    comment.reload
    assert_equal action_payload, JSON.parse(comment.action)
    assert_equal @user.id, comment.approver.id
    assert_not_nil comment.action_executed_at
    assert_equal @user.id, comment.action_executed_by.id
    assert_in_delta 0.9, comment.creative.reload.progress
  end

  test "approved onboarding create returns card root and created creative refresh ids" do
    @user.update!(onboarding_seeded_at: nil, onboarding_completed_at: nil)
    Creative.inbox_for(@user)
    guide = Collavre::Onboarding::Seeder.call(user: @user)
    card = guide.children.find { |creative| creative.onboarding_metadata["step_key"] == "create_edit" }
    comment = card.comments.create!(
      content: "Create a practice Creative",
      user: @user,
      action: JSON.generate(
        "action" => "create_creative",
        "attributes" => { "description" => "First draft" }
      ),
      approver: @user,
      skip_dispatch: true
    )

    post approve_creative_comment_path(card, comment)

    assert_response :success
    practice = Creative.find(card.reload.onboarding_metadata["target_creative_id"])
    assert_equal card.id.to_s, response.headers["X-Onboarding-Card-Id"]
    assert_equal guide.id.to_s, response.headers["X-Onboarding-Root-Id"]
    assert_equal practice.id.to_s, response.headers["X-Onboarding-Created-Creative-Id"]
    assert_equal "in_progress", card.onboarding_metadata["status"]
  end

  test "cannot execute comment action more than once" do
    action_payload = {
      "action" => "update_creative",
      "attributes" => { "progress" => 0.9 }
    }

    comment = @creative.comments.create!(
      content: "Run action",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @user
    )

    post approve_creative_comment_path(@creative, comment)
    assert_response :success

    post approve_creative_comment_path(@creative, comment)

    assert_response :unprocessable_entity
    response_body = JSON.parse(@response.body)
    assert_equal I18n.t("collavre.comments.approve_already_executed"), response_body["error"]
  end

  test "non approver cannot execute comment action" do
    approver = users(:two)
    action_payload = {
      "action" => "update_creative",
      "attributes" => { "progress" => 0.9 }
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate(action_payload),
      approver: approver
    )

    assert_no_changes -> { comment.reload.action } do
      post approve_creative_comment_path(@creative, comment)
      assert_response :forbidden
    end
  end

  # --- Claude Channel tool-permission decisions ---
  #
  # These reuse the approval comment UI but resolve by relaying the decision to
  # the suspended Claude Code session over the agent stream — the tool runs in
  # the remote process, never via ActionExecutor.

  def claude_channel_agent
    User.create!(
      email: "ccp_ctrl_agent@agent.collavre.local",
      name: "Claude Channel Session",
      password: "password",
      llm_vendor: "anthropic",
      llm_model: "claude-code",
      created_by_id: @user.id
    )
  end

  def claude_channel_permission_comment(request_id: "req-1")
    agent = claude_channel_agent
    payload = {
      "action" => Collavre::Comment::ClaudeChannelPermission::ACTION_TYPE,
      "request_id" => request_id,
      "tool_name" => "Bash",
      "arguments" => { "command" => "ls" }
    }
    @creative.comments.create!(
      content: "needs approval",
      user: agent,
      approver: @user,
      action: JSON.pretty_generate(payload),
      skip_default_user: true,
      skip_dispatch: true
    )
  end

  test "approving a Claude Channel permission relays allow and does not run ActionExecutor" do
    comment = claude_channel_permission_comment(request_id: "req-allow")

    # If ActionExecutor were invoked it would raise on this unknown action type;
    # a successful 200 proves the channel branch bypassed it.
    ::Comments::ActionExecutor.stub(:new, ->(*) { raise "ActionExecutor must not run for channel permissions" }) do
      assert_broadcasts("agent:user:#{comment.user_id}", 1) do
        post approve_creative_comment_path(@creative, comment)
      end
    end

    assert_response :success
    assert_includes @response.body, I18n.t("collavre.comments.approved_label")
    comment.reload
    assert_not_nil comment.action_executed_at
    refute comment.claude_channel_permission_denied?
  end

  test "denying a Claude Channel permission relays deny and marks the comment denied" do
    comment = claude_channel_permission_comment(request_id: "req-deny")

    payload = capture_broadcasts("agent:user:#{comment.user_id}") do
      post deny_creative_comment_path(@creative, comment)
    end.first

    assert_response :success
    assert_includes @response.body, I18n.t("collavre.comments.denied_label")
    assert_equal "deny", payload["behavior"]
    assert_equal "req-deny", payload["request_id"]
    assert comment.reload.claude_channel_permission_denied?
  end

  test "a Claude Channel permission cannot be decided twice" do
    comment = claude_channel_permission_comment

    post approve_creative_comment_path(@creative, comment)
    assert_response :success

    post deny_creative_comment_path(@creative, comment)
    assert_response :unprocessable_entity
    assert_equal I18n.t("collavre.comments.approve_already_executed"), JSON.parse(@response.body)["error"]
  end

  test "non-approver cannot decide a Claude Channel permission" do
    approver = users(:two)
    approver.update!(email_verified_at: Time.current)
    comment = claude_channel_permission_comment
    comment.update!(approver: approver)

    assert_no_changes -> { comment.reload.action_executed_at } do
      post approve_creative_comment_path(@creative, comment)
      assert_response :forbidden
      post deny_creative_comment_path(@creative, comment)
      assert_response :forbidden
    end
  end

  test "deny is rejected for a non-Claude-Channel approval comment" do
    comment = @creative.comments.create!(
      content: "Run action",
      user: @user,
      action: JSON.generate({ "action" => "update_creative", "attributes" => { "progress" => 0.9 } }),
      approver: @user
    )

    post deny_creative_comment_path(@creative, comment)
    assert_response :forbidden
  end

  test "approver can execute private comment action" do
    approver = users(:two)
    approver.update!(email_verified_at: Time.current)
    grant_read_access_to_other_user(user: approver, permission: :write)

    action_payload = {
      "action" => "update_creative",
      "attributes" => { "progress" => 0.9 }
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      private: true,
      action: JSON.generate(action_payload),
      approver: approver
    )

    delete session_path
    post session_path, params: { email: approver.email, password: "password" }

    post approve_creative_comment_path(@creative, comment)

    assert_response :success
    assert_not_nil comment.reload.action_executed_at
  end

  test "approver sees private comments in index" do
    other_user = users(:two)
    other_user.update!(email_verified_at: Time.current)

    comment = @creative.comments.create!(
      content: "Private for approver",
      user: other_user,
      private: true,
      approver: @user
    )

    get creative_comments_path(@creative), params: { page: 1, per_page: 10 }

    assert_response :success
    assert_includes @response.body, comment.content
  end

  test "commenters cannot set approval attributes when creating" do
    assert_difference("Comment.count", 1) do
      post creative_comments_path(@creative), params: {
        comment: {
          content: "Needs approval",
          private: false,
          action: "User.count",
          approver_id: @user.id
        }
      }
    end

    comment = @creative.comments.order(:id).last
    assert_nil comment.action
    assert_nil comment.approver_id
  end

  test "user can attach images to a comment" do
    assert_difference -> { ActiveStorage::Attachment.where(record_type: [ "Comment", "Collavre::Comment" ]).count }, 1 do
      post creative_comments_path(@creative), params: {
        comment: {
          content: "",
          images: [ fixture_file_upload(file_fixture("small.png"), "image/png") ]
        }
      }

      assert_response :created
    end

    comment = @creative.comments.order(:id).last
    assert comment.images.attached?
  end

  test "rejects non-image attachments on comments" do
    assert_no_difference [ "Comment.count", "ActiveStorage::Attachment.count", "ActiveStorage::Blob.count" ] do
      post creative_comments_path(@creative), params: {
        comment: {
          content: "",
          images: [ fixture_file_upload(file_fixture("invalid.txt"), "text/plain") ]
        }
      }

      assert_response :unprocessable_entity
    end

    errors = JSON.parse(@response.body)["errors"]
    assert_includes errors, "Images must be an image"
  end

  test "commenters cannot set approval attributes when updating" do
    comment = @creative.comments.create!(content: "Needs approval", user: @user)

    patch creative_comment_path(@creative, comment), params: {
      comment: {
        content: "Updated",
        action: "User.count",
        approver_id: @user.id
      }
    }

    comment.reload
    assert_equal "Updated", comment.content
    assert_nil comment.action
    assert_nil comment.approver_id
  end

  test "user can uncheck private checkbox when updating comment" do
    comment = @creative.comments.create!(content: "Secret", user: @user, private: true)
    assert comment.private?, "Comment should start as private"

    patch creative_comment_path(@creative, comment), params: {
      comment: {
        content: "No longer secret",
        private: "0"
      }
    }

    assert_response :success
    comment.reload
    assert_equal "No longer secret", comment.content
    assert_not comment.private?, "Comment should no longer be private after unchecking"
  end

  test "user can check private checkbox when updating comment" do
    comment = @creative.comments.create!(content: "Public", user: @user, private: false)
    assert_not comment.private?, "Comment should start as public"

    patch creative_comment_path(@creative, comment), params: {
      comment: {
        content: "Now secret",
        private: "1"
      }
    }

    assert_response :success
    comment.reload
    assert_equal "Now secret", comment.content
    assert comment.private?, "Comment should be private after checking"
  end

  test "user can move comments to another creative" do
    target = creatives(:childless_creative)
    comment = @creative.comments.create!(content: "Move me", user: @user)

    assert_changes -> { comment.reload.creative_id }, from: @creative.id, to: target.effective_origin.id do
      post move_creative_comments_path(@creative), params: {
        comment_ids: [ comment.id ],
        target_creative_id: target.id
      }, as: :json
      assert_response :success
    end

    response_body = JSON.parse(@response.body)
    assert_equal true, response_body["success"]
  end

  test "cannot move comments without permission on target" do
    other_user = users(:two)
    other_user.update!(email_verified_at: Time.current)
    target = Creative.create!(user: other_user, description: "Restricted", progress: 0.0)
    comment = @creative.comments.create!(content: "Move me", user: @user)

    assert_no_changes -> { comment.reload.creative_id } do
      post move_creative_comments_path(@creative), params: {
        comment_ids: [ comment.id ],
        target_creative_id: target.id
      }, as: :json
      assert_response :forbidden
    end

    response_body = JSON.parse(@response.body)
    assert_equal I18n.t("collavre.comments.move_not_allowed"), response_body["error"]
  end

  test "approver can update comment action" do
    action_payload = {
      "action" => "update_creative",
      "attributes" => { "progress" => 0.5 }
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @user
    )

    updated_payload = {
      "action" => "update_creative",
      "attributes" => { "progress" => 0.75 }
    }

    patch update_action_creative_comment_path(@creative, comment), params: {
      comment: { action: JSON.generate(updated_payload) }
    }

    assert_response :success
    comment.reload
    assert_equal updated_payload, JSON.parse(comment.action)
  end

  test "approver cannot update action with invalid payload" do
    action_payload = {
      "action" => "update_creative",
      "attributes" => { "progress" => 0.5 }
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @user
    )

    patch update_action_creative_comment_path(@creative, comment), params: {
      comment: { action: "{ invalid json" }
    }

    assert_response :unprocessable_entity
    body = JSON.parse(@response.body)
    assert_equal I18n.t("collavre.comments.approve_invalid_format"), body["error"]
    assert_equal action_payload, JSON.parse(comment.reload.action)
  end

  test "creative admin can update action even if not the approver" do
    approver = users(:two)
    approver.update!(email_verified_at: Time.current)

    action_payload = {
      "action" => "update_creative",
      "attributes" => { "progress" => 0.5 }
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: approver,
      action: JSON.generate(action_payload),
      approver: approver
    )

    updated_payload = action_payload.merge("attributes" => { "progress" => 0.7 })

    patch update_action_creative_comment_path(@creative, comment), params: {
      comment: { action: JSON.generate(updated_payload) }
    }

    assert_response :success
    comment.reload
    assert_equal updated_payload, JSON.parse(comment.action)
  end

  test "non admin non approver cannot update comment action" do
    approver = users(:two)
    approver.update!(email_verified_at: Time.current)
    # Create a third user who has only read access (not admin)
    reader = users(:three)
    reader.update!(email_verified_at: Time.current)
    grant_read_access_to_other_user(@creative, user: reader, permission: :feedback)

    action_payload = {
      "action" => "update_creative",
      "attributes" => { "progress" => 0.5 }
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: approver,
      action: JSON.generate(action_payload),
      approver: approver
    )

    # Log in as reader (non-admin, non-approver)
    post session_path, params: { email: reader.email, password: "password" }

    patch update_action_creative_comment_path(@creative, comment), params: {
      comment: { action: JSON.generate(action_payload.merge("attributes" => { "progress" => 0.7 })) }
    }

    assert_response :forbidden
  end

  test "cannot update action after execution" do
    action_payload = {
      "action" => "update_creative",
      "attributes" => { "progress" => 0.5 }
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @user,
      action_executed_at: Time.current,
      action_executed_by: @user
    )

    patch update_action_creative_comment_path(@creative, comment), params: {
      comment: { action: JSON.generate(action_payload.merge("attributes" => { "progress" => 0.8 })) }
    }

    assert_response :unprocessable_entity
    body = JSON.parse(@response.body)
    assert_equal I18n.t("collavre.comments.approve_already_executed"), body["error"]
  end

  test "comment owner can delete their own comment" do
    comment = @creative.comments.create!(content: "My comment", user: @user)

    assert_difference("Comment.count", -1) do
      delete creative_comment_path(@creative, comment)
    end

    assert_response :no_content
  end

  test "creative owner can delete any comment" do
    other_user = users(:two)
    other_user.update!(email_verified_at: Time.current)
    comment = @creative.comments.create!(content: "Other user comment", user: other_user)

    inbox = Creative.inbox_for(other_user)
    inbox_before = inbox.comments.count

    delete creative_comment_path(@creative, comment)

    assert_response :no_content

    # Verify inbox notification comment was created
    assert_equal inbox_before + 1, inbox.comments.reload.count
    inbox_comment = inbox.comments.order(:id).last
    assert_nil inbox_comment.user
    assert_includes inbox_comment.content, "Other user comment"
  end

  test "admin user can delete any comment" do
    other_user = users(:two)
    other_user.update!(email_verified_at: Time.current)

    other_creative = nil
    perform_enqueued_jobs do
      # Create a creative owned by other_user
      other_creative = Creative.create!(user: other_user, description: "Other creative", progress: 0.0)

      # Share with admin permission to @user
      CreativeShare.create!(creative: other_creative, user: @user, permission: :admin, shared_by: other_user)
    end

    # Create comment by other_user
    comment = other_creative.comments.create!(content: "Comment to delete", user: other_user)

    inbox = Creative.inbox_for(other_user)
    inbox_before = inbox.comments.count

    delete creative_comment_path(other_creative, comment)

    assert_response :no_content
    # Inbox notification comment created for the deleted comment's author
    assert_equal inbox_before + 1, inbox.comments.reload.count
  end

  test "non-owner non-admin cannot delete comment" do
    other_user = users(:two)
    other_user.update!(email_verified_at: Time.current)
    comment = @creative.comments.create!(content: "Protected comment", user: other_user)

    # Login as a different user
    third_user = User.create!(
      name: "Third User",
      email: "third@example.com",
      password: "password",
      email_verified_at: Time.current
    )
    delete session_path
    post session_path, params: { email: third_user.email, password: "password" }

    assert_no_difference("Comment.count") do
      delete creative_comment_path(@creative, comment)
    end

    assert_response :forbidden
  end

  test "deleting AI user comment does not create inbox notification" do
    ai_user = User.create!(
      name: "AI Bot",
      email: "aibot@ai.local",
      password: SecureRandom.hex(32),
      llm_vendor: "google",
      llm_model: "gemini-3-flash-preview",
      system_prompt: "I am a bot",
      email_verified_at: Time.current
    )

    comment = @creative.comments.create!(content: "AI response", user: ai_user)

    delete creative_comment_path(@creative, comment)
    assert_response :no_content
  end

  test "comment owner deleting own comment does not create inbox notification" do
    comment = @creative.comments.create!(content: "My own comment", user: @user)
    inbox = Creative.inbox_for(@user)
    inbox_before = inbox.comments.count

    delete creative_comment_path(@creative, comment)

    assert_response :no_content
    # No inbox notification for deleting own comment
    assert_equal inbox_before, inbox.comments.reload.count
  end

  test "main topic view shows all comments and renders topic links" do
    topic = @creative.topics.create!(name: "Design", user: @user)
    main_comment = @creative.comments.create!(content: "Main lane comment", user: @user)
    topic_comment = @creative.comments.create!(content: "Topic specific", user: @user, topic: topic)

    get creative_comments_path(@creative)

    assert_response :success
    assert_includes @response.body, main_comment.content
    assert_includes @response.body, topic_comment.content
    assert_includes @response.body, "comment-topic-switch"
    assert_includes @response.body, "##{topic.name}"
  end

  test "topic view hides topic links and filters comments" do
    topic = @creative.topics.create!(name: "Design", user: @user)
    other_comment = @creative.comments.create!(content: "Main lane comment", user: @user)
    topic_comment = @creative.comments.create!(content: "Topic specific", user: @user, topic: topic)

    get creative_comments_path(@creative), params: { topic_id: topic.id }

    assert_response :success
    assert_includes @response.body, topic_comment.content
    assert_not_includes @response.body, other_comment.content
    assert_not_includes @response.body, "comment-topic-switch"
  end


  test "approve returns 422 for missing action" do
    comment = @creative.comments.create!(content: "No action", user: @user, approver: @user)
    post approve_creative_comment_path(@creative, comment)
    assert_response :unprocessable_entity
    assert_equal I18n.t("collavre.comments.approve_missing_action"), JSON.parse(@response.body)["error"]
  end

  test "approve returns 422 for missing approver" do
    action_payload = { "action" => "update_creative", "attributes" => { "progress" => 0.5 } }
    comment = @creative.comments.create!(
      content: "No approver",
      user: @user,
      action: JSON.generate(action_payload),
      approver: nil
    )
    post approve_creative_comment_path(@creative, comment)
    assert_response :unprocessable_entity
    assert_equal I18n.t("collavre.comments.approve_missing_approver"), JSON.parse(@response.body)["error"]
  end

  test "approve returns 403 with specific message when admin approval required" do
    SystemSetting.create!(key: "mcp_tool_approval_required", value: "true")
    # Reset Current to ensure setting is picked up if it was already cached (though setup clears it)
    Current.reset

    non_admin = users(:two)
    non_admin.update!(email_verified_at: Time.current)
    grant_read_access_to_other_user(user: non_admin)

    # Sign in as non-admin
    delete session_path
    post session_path, params: { email: non_admin.email, password: "password" }

    action_payload = { "action" => "approve_tool", "tool_name" => "test_tool" }
    comment = @creative.comments.create!(
      content: "Approve tool",
      user: @user,
      action: JSON.generate(action_payload),
      approver: non_admin
    )

    # non_admin is not system admin
    post approve_creative_comment_path(@creative, comment)
    assert_response :forbidden
    assert_equal I18n.t("collavre.comments.approve_admin_required"), JSON.parse(@response.body)["error"]

    # Cleanup
    SystemSetting.where(key: "mcp_tool_approval_required").destroy_all

    # Restore session for other tests if needed (though teardown handles generic cleanup)
    delete session_path
    post session_path, params: { email: @user.email, password: "password" }
  end

  test "approver can update action even if current action is invalid" do
    comment = @creative.comments.create!(
      content: "Broken action",
      user: @user,
      action: "invalid json }",
      approver: @user
    )

    new_payload = { "action" => "update_creative", "attributes" => { "progress" => 0.5 } }

    patch update_action_creative_comment_path(@creative, comment), params: {
      comment: { action: JSON.generate(new_payload) }
    }

    assert_response :success
    comment.reload
    assert_equal new_payload, JSON.parse(comment.action)
  end


  test "non-approver receives 403 (not 422) for blank action payload" do
    non_approver = users(:two)
    non_approver.update!(email_verified_at: Time.current)
    grant_read_access_to_other_user(user: non_approver)

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate({ "action" => "update_creative", "attributes" => { "progress" => 0.5 } }),
      approver: @user
    )

    # Sign in as non-approver
    delete session_path
    post session_path, params: { email: non_approver.email, password: "password" }

    # Send blank action - should fail usage check FIRST (return 403), instead of 422
    patch update_action_creative_comment_path(@creative, comment), params: {
      comment: { action: "" }
    }

    assert_response :forbidden
    assert_equal I18n.t("collavre.comments.approve_not_allowed"), JSON.parse(@response.body)["error"]

    # Restore session
    delete session_path
    post session_path, params: { email: @user.email, password: "password" }
  end

  test "approve action performs authz check before content validation" do
    non_approver = users(:two)
    non_approver.update!(email_verified_at: Time.current)
    grant_read_access_to_other_user(user: non_approver)

    # Comment with NO action (invalid state usually, but possible via direct DB creation or bugs)
    comment = @creative.comments.create!(
      content: "No action",
      user: @user,
      action: nil,
      approver: @user
    )

    # Sign in as non-approver
    delete session_path
    post session_path, params: { email: non_approver.email, password: "password" }

    # Try to approve - should get 403 (Not Allowed), NOT 422 (Missing Action)
    post approve_creative_comment_path(@creative, comment)

    assert_response :forbidden
    assert_equal I18n.t("collavre.comments.approve_not_allowed"), JSON.parse(@response.body)["error"]

    # Restore session
    delete session_path
    post session_path, params: { email: @user.email, password: "password" }
  end

  test "non-approver receives 403 (not 422) for invalid action payload" do
    non_approver = users(:two)
    non_approver.update!(email_verified_at: Time.current)
    grant_read_access_to_other_user(user: non_approver)

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate({ "action" => "update_creative", "attributes" => { "progress" => 0.5 } }),
      approver: @user
    )

    # Sign in as non-approver
    delete session_path
    post session_path, params: { email: non_approver.email, password: "password" }

    # Send invalid JSON - should fail usage check FIRST (return 403), instead of 422
    patch update_action_creative_comment_path(@creative, comment), params: {
      comment: { action: "invalid json }" }
    }

    assert_response :forbidden
    assert_equal I18n.t("collavre.comments.approve_not_allowed"), JSON.parse(@response.body)["error"]

    # Restore session
    delete session_path
    post session_path, params: { email: @user.email, password: "password" }
  end

  test "non-approver cannot repair invalid action" do
    non_approver = users(:two)
    non_approver.update!(email_verified_at: Time.current)
    grant_read_access_to_other_user(user: non_approver)

    comment = @creative.comments.create!(
      content: "Broken action",
      user: @user,
      action: "invalid json }",
      approver: @user
    )

    # Sign in as non-approver
    delete session_path
    post session_path, params: { email: non_approver.email, password: "password" }

    # Attempt to repair with valid JSON
    new_payload = { "action" => "update_creative", "attributes" => { "progress" => 0.5 } }
    patch update_action_creative_comment_path(@creative, comment), params: {
      comment: { action: JSON.generate(new_payload) }
    }

    assert_response :forbidden

    # Restore session
    delete session_path
    post session_path, params: { email: @user.email, password: "password" }
  end

  test "commands returns static calendar command" do
    get commands_creative_comments_path(@creative), headers: { "Accept" => "application/json" }

    assert_response :success
    json = JSON.parse(response.body)

    calendar_command = json.find { |cmd| cmd["name"] == "calendar" }
    assert_not_nil calendar_command, "Calendar command should be present"
    assert_equal "/calendar", calendar_command["label"]
    assert_includes calendar_command["aliases"], "/cal"
  end

  test "commands returns system MCP tools" do
    skip "RailsMcpEngine not available" unless defined?(RailsMcpEngine)

    get commands_creative_comments_path(@creative), headers: { "Accept" => "application/json" }

    assert_response :success
    json = JSON.parse(response.body)

    # creative_retrieval_service is a system tool, should be included
    retrieval_tool = json.find { |cmd| cmd["name"] == "creative_retrieval_service" }
    assert_not_nil retrieval_tool, "System tool creative_retrieval_service should be present"
    assert_equal "/creative_retrieval_service", retrieval_tool["label"]
  end

  test "commands excludes dynamic tools user does not have permission for" do
    skip "RailsMcpEngine not available" unless defined?(RailsMcpEngine)

    # Create a tool owned by another user
    other_user = users(:two)
    other_creative = Creative.create!(user: other_user, description: "Other user's creative")
    McpTool.create!(creative: other_creative, name: "private_test_tool", source_code: "class Foo; end")

    get commands_creative_comments_path(@creative), headers: { "Accept" => "application/json" }

    assert_response :success
    json = JSON.parse(response.body)

    # Should not include the private tool
    private_tool = json.find { |cmd| cmd["name"] == "private_test_tool" }
    assert_nil private_tool, "Private tool should not be present for unauthorized user"
  end

  test "commands includes dynamic tools user has write permission for" do
    skip "RailsMcpEngine not available" unless defined?(RailsMcpEngine)

    # Create a tool owned by the current user
    my_creative = Creative.create!(user: @user, description: "My creative")
    McpTool.create!(creative: my_creative, name: "my_test_tool", source_code: "class Foo; end")

    # Stub available_tools to return a tool list that includes the user's tool
    mock_tools = [
      { name: "creative_retrieval_service", description: "System tool" },
      { name: "my_test_tool", description: "User's tool" }
    ]

    Collavre::McpService.stub(:available_tools, ->(user) { Collavre::McpService.filter_tools(mock_tools, user) }) do
      get commands_creative_comments_path(@creative), headers: { "Accept" => "application/json" }
    end

    assert_response :success
    json = JSON.parse(response.body)

    # Should include the user's own tool
    my_tool = json.find { |cmd| cmd["name"] == "my_test_tool" }
    assert_not_nil my_tool, "User's own tool should be present"
  end

  test "commands requires read permission on creative" do
    other_user = users(:two)
    other_user.update!(email_verified_at: Time.current)
    private_creative = Creative.create!(user: other_user, description: "Private")

    get commands_creative_comments_path(private_creative), headers: { "Accept" => "application/json" }

    assert_response :forbidden
  end

  test "participants returns permission flags for admin" do
    get participants_creative_comments_path(@creative), headers: { "Accept" => "application/json" }
    assert_response :success
    data = JSON.parse(response.body)
    assert data.key?("users"), "Response should include users array"
    assert data.key?("can_share"), "Response should include can_share flag"
    assert data.key?("can_comment"), "Response should include can_comment flag"
    assert data.key?("has_access"), "Response should include has_access flag"
    assert_equal true, data["can_share"]
    assert_equal true, data["can_comment"]
    assert_equal true, data["has_access"]
    assert_kind_of Array, data["users"]
    assert data["users"].any? { |u| u["id"] == @user.id }
  end

  test "participants returns correct permission flags for non-admin shared user" do
    other = users(:two)
    other.update!(email_verified_at: Time.current)
    grant_read_access_to_other_user(user: other, permission: :feedback)

    # Login as the shared user
    post session_path, params: { email: other.email, password: "password" }

    get participants_creative_comments_path(@creative), headers: { "Accept" => "application/json" }
    assert_response :success
    data = JSON.parse(response.body)
    assert_equal false, data["can_share"]
    assert_equal true, data["can_comment"]
    assert_equal true, data["has_access"]
  end

  test "participants excludes read-only shared users" do
    other = users(:two)
    other.update!(email_verified_at: Time.current)
    grant_read_access_to_other_user(user: other, permission: :read)

    get participants_creative_comments_path(@creative), headers: { "Accept" => "application/json" }

    assert_response :success
    data = JSON.parse(response.body)
    refute data["users"].any? { |u| u["id"] == other.id }
  end

  test "participants disables caching" do
    get participants_creative_comments_path(@creative), headers: { "Accept" => "application/json" }

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-cache", response.headers["Pragma"]
    assert_equal "0", response.headers["Expires"]
  end

  test "index shows feature discovery cards when there are no comments" do
    get creative_comments_path(@creative)

    assert_response :success
    assert_includes @response.body, 'id="no-comments"'
    assert_includes @response.body, I18n.t("collavre.comments.empty_state.title")
    %w[mention_agent slash_command chat_context automation_trigger topic_management add_user].each do |key|
      assert_includes @response.body, %(data-key="#{key}")
    end
    assert_not_includes @response.body, %(data-key="inbox_notifications")
  end

  test "index shows notification guidance for an empty inbox System topic" do
    inbox = Creative.inbox_for(@user)
    system_topic = inbox.system_topic

    get creative_comments_path(inbox), params: { topic_id: system_topic.id }

    assert_response :success
    assert_includes @response.body, I18n.t("collavre.comments.empty_state.inbox_system_title")
    %w[inbox_notifications inbox_reply inbox_source].each do |key|
      assert_includes @response.body, %(data-key="#{key}")
      assert_includes @response.body, %(href="/features/#{key}?locale=en")
    end
    assert_not_includes @response.body, %(data-key="mention_agent")
    assert_not_includes @response.body, I18n.t("collavre.comments.empty_state.title")
  end

  test "index uses the notification-specific minimal state when System cards are dismissed" do
    inbox = Creative.inbox_for(@user)
    system_topic = inbox.system_topic
    @user.update!(dismissed_notices: %w[inbox_notifications inbox_reply inbox_source])

    get creative_comments_path(inbox), params: { topic_id: system_topic.id }

    assert_response :success
    assert_includes @response.body,
                    ERB::Util.html_escape(I18n.t("collavre.comments.empty_state.inbox_system_minimal_prompt"))
    assert_not_includes @response.body, "feature-card-grid"
    assert_not_includes @response.body, I18n.t("collavre.comments.empty_state.minimal_prompt")
  end

  test "index keeps regular guidance in non-System inbox topics" do
    inbox = Creative.inbox_for(@user)
    main_topic = inbox.main_topic

    get creative_comments_path(inbox), params: { topic_id: main_topic.id }

    assert_response :success
    assert_includes @response.body, %(data-key="mention_agent")
    assert_not_includes @response.body, %(data-key="inbox_notifications")
  end

  test "create does not execute slash commands in the inbox System topic" do
    inbox = Creative.inbox_for(@user)
    system_topic = inbox.system_topic
    2.times do |index|
      inbox.comments.create!(
        topic: system_topic,
        content: "System notification #{index}",
        user: nil,
        skip_default_user: true
      )
    end

    ::Comments::CommandProcessor.stub(:new, ->(*) { flunk("System comments must skip command processing") }) do
      post creative_comments_path(inbox), params: {
        comment: { content: "/compress", topic_id: system_topic.id }
      }
    end

    assert_response :created
    assert_equal "/compress", inbox.comments.order(:id).last.content
  end

  # Phase 1 shipped the cards with the guide link suppressed because no page
  # existed to link to. Now that /features/:key is routed, every card carries it.
  test "index links each feature card to its public guide page" do
    get creative_comments_path(@creative)

    assert_response :success
    assert_includes @response.body, I18n.t("collavre.comments.empty_state.learn_more")
    %w[mention_agent slash_command chat_context automation_trigger topic_management add_user].each do |key|
      assert_includes @response.body, %(href="/features/#{key}?locale=en"),
                      "expected the #{key} card to link its guide in the active locale"
    end
  end

  test "index keeps the engine mount prefix in feature guide links" do
    get creative_comments_path(@creative), env: { "SCRIPT_NAME" => "/collavre" }

    assert_response :success
    %w[mention_agent slash_command chat_context automation_trigger topic_management add_user].each do |key|
      assert_includes @response.body, %(href="/collavre/features/#{key}?locale=en"),
                      "expected the #{key} card guide to retain the mount prefix"
    end
  end

  test "index hides dismissed feature cards but keeps the rest" do
    @user.update!(dismissed_notices: [ "slash_command" ])

    get creative_comments_path(@creative)

    assert_response :success
    assert_not_includes @response.body, %(data-key="slash_command")
    assert_includes @response.body, %(data-key="add_user")
  end

  test "index shows the minimal empty state once every card is dismissed" do
    @user.update!(dismissed_notices: %w[mention_agent slash_command chat_context automation_trigger topic_management add_user])

    get creative_comments_path(@creative)

    assert_response :success
    assert_includes @response.body, I18n.t("collavre.comments.empty_state.minimal_prompt")
    assert_not_includes @response.body, "feature-card-grid"
  end

  test "index hides the add_user card for a user without admin permission" do
    non_admin = users(:two)
    grant_read_access_to_other_user(user: non_admin, permission: :feedback)
    delete session_path
    post session_path, params: { email: non_admin.email, password: "password" }

    get creative_comments_path(@creative)

    assert_response :success
    assert_not_includes @response.body, %(data-key="add_user")
    assert_includes @response.body, %(data-key="slash_command")
  end

  test "index hides the slash_command card for a user without feedback permission" do
    read_only = users(:two)
    grant_read_access_to_other_user(user: read_only, permission: :read)
    delete session_path
    post session_path, params: { email: read_only.email, password: "password" }

    get creative_comments_path(@creative)

    assert_response :success
    assert_not_includes @response.body, %(data-key="slash_command")
    assert_includes @response.body, %(data-key="topic_management")
  end

  test "index hides the slash_command card for an archived creative even for the owner" do
    @creative.update!(archived_at: Time.current)

    get creative_comments_path(@creative)

    assert_response :success
    assert_not_includes @response.body, %(data-key="slash_command")
    assert_includes @response.body, %(data-key="topic_management")
  end

  test "index shows a no-results message instead of feature cards when a search has no matches" do
    get creative_comments_path(@creative), params: { search: "no such comment exists" }

    assert_response :success
    assert_includes @response.body, 'id="no-search-results"'
    assert_includes @response.body, I18n.t("collavre.comments.empty_state.no_search_results")
    assert_not_includes @response.body, 'id="no-comments"'
  end

  test "index shows feature cards for an empty topic in an existing conversation" do
    @creative.comments.create!(content: "Main lane comment", user: @user)
    empty_topic = @creative.topics.create!(name: "Fresh", user: @user)

    get creative_comments_path(@creative), params: { topic_id: empty_topic.id }

    assert_response :success
    assert_includes @response.body, 'id="no-comments"'
    assert_includes @response.body, I18n.t("collavre.comments.empty_state.title")
    assert_includes @response.body, %(data-key="mention_agent")
  end

  test "index still shows feature cards for an empty topic when the creative has no comments at all" do
    empty_topic = @creative.topics.create!(name: "Fresh", user: @user)

    get creative_comments_path(@creative), params: { topic_id: empty_topic.id }

    assert_response :success
    assert_includes @response.body, 'id="no-comments"'
    assert_includes @response.body, %(data-key="mention_agent")
  end

  # A comment from another participant arrives as a Turbo Stream append into
  # #comments-list and never reaches comments--form#removePlaceholder, so every
  # empty-list state has to clear itself via comments--placeholder.
  test "index wires the discovery cards to the placeholder controller" do
    get creative_comments_path(@creative)

    assert_response :success
    assert_includes @response.body, %(data-controller="comments--feature-cards comments--placeholder")
  end

  test "index wires the no-results message to the placeholder controller" do
    get creative_comments_path(@creative), params: { search: "no such comment exists" }

    assert_response :success
    assert_includes @response.body,
                    %(<div id="no-search-results" class="comments-placeholder" data-controller="comments--placeholder">)
  end

  test "index wires empty-topic feature cards to the placeholder controller" do
    @creative.comments.create!(content: "Main lane comment", user: @user)
    empty_topic = @creative.topics.create!(name: "Fresh", user: @user)

    get creative_comments_path(@creative), params: { topic_id: empty_topic.id }

    assert_response :success
    assert_includes @response.body, 'data-controller="comments--feature-cards comments--placeholder"'
  end
end
