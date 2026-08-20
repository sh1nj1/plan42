require "test_helper"

class TopicsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @creative = creatives(:tshirt)
    @user = users(:one)
    @topic = @creative.topics.create!(name: "Existing Topic", user: @user)
    sign_in_as @user, password: "password"
  end

  test "index returns effective_creative_id for non-linked creative" do
    get collavre.creative_topics_url(@creative), as: :json
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal @creative.id, json["effective_creative_id"]
  end

  test "index returns the last topic revision" do
    preference = Collavre::UserCreativePreference.create!(
      creative: @creative,
      user: @user,
      expanded_status: {},
      last_topic: @topic,
      last_topic_revision: 7
    )

    get collavre.creative_topics_url(@creative), as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal @topic.id, json["last_topic_id"]
    assert_equal [ preference.id, 7 ], json["last_topic_revision"]
  end

  test "index returns the revision of a cleared last topic" do
    preference = Collavre::UserCreativePreference.create!(
      creative: @creative,
      user: @user,
      expanded_status: {},
      last_topic_revision: 2
    )

    get collavre.creative_topics_url(@creative), as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_nil json["last_topic_id"]
    assert_equal [ preference.id, 2 ], json["last_topic_revision"]
  end

  test "index includes unread counts for active and archived topics" do
    archived_topic = @creative.topics.create!(name: "Archived", user: @user)
    archived_topic.archive!
    read_comment = Collavre::Comment.create!(creative: @creative, topic: @topic, user: users(:two), content: "read")
    Collavre::Comment.create!(creative: @creative, topic: @topic, user: users(:two), content: "active unread")
    Collavre::Comment.create!(creative: @creative, topic: archived_topic, user: users(:two), content: "archived unread")
    Collavre::CommentReadPointer.create!(user: @user, creative: @creative, last_read_comment_id: read_comment.id)

    get collavre.creative_topics_url(@creative), as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal 1, json["topics"].find { |topic| topic["id"] == @topic.id }["unread_count"]
    assert_equal 1, json["archived_topics"].find { |topic| topic["id"] == archived_topic.id }["unread_count"]
  end

  test "index returns effective_creative_id for linked creative (origin id)" do
    linked = Collavre::Creative.create!(user: @user, description: "linked wrapper", origin: @creative)
    get collavre.creative_topics_url(linked), as: :json
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal @creative.id, json["effective_creative_id"]
  end

  # set_primary_agent is guarded by require_creative_write!, so the client needs a
  # write-level capability to gate the release control on. Reporting only
  # can_manage (:admin) would let a write collaborator pin an agent by dropping it
  # on the topic and then leave them no way to release it.
  test "index reports can_set_primary_agent for a write collaborator who cannot manage" do
    collaborator = users(:two)
    Collavre::CreativeShare.create!(creative: @creative, user: collaborator, shared_by: @user, permission: :write)
    sign_in_as collaborator, password: "password"

    get collavre.creative_topics_url(@creative), as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_not json["can_manage"], "write collaborator must not be reported as a manager"
    assert json["can_set_primary_agent"], "write collaborator must be able to release an assignment"
  end

  test "index withholds can_set_primary_agent from a read-only collaborator" do
    collaborator = users(:two)
    Collavre::CreativeShare.create!(creative: @creative, user: collaborator, shared_by: @user, permission: :read)
    sign_in_as collaborator, password: "password"

    get collavre.creative_topics_url(@creative), as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_not json["can_set_primary_agent"]
  end

  test "index eagerly creates System topic on first inbox visit so badge has matching topic" do
    inbox = Collavre::Creative.inbox_for(@user)
    inbox.topics.where(name: Collavre::Creative::SYSTEM_TOPIC_NAME).destroy_all

    assert_nil inbox.topics.find_by(name: Collavre::Creative::SYSTEM_TOPIC_NAME),
      "precondition: System topic should not exist before first visit"

    get collavre.creative_topics_url(inbox), as: :json

    assert_response :success
    json = JSON.parse(response.body)

    assert json["is_inbox"], "fixture must be an inbox"
    assert json["system_topic_id"].present?, "system_topic_id must be returned"

    system_topic = inbox.topics.find_by(name: Collavre::Creative::SYSTEM_TOPIC_NAME)
    assert system_topic.present?, "System topic must be created by index"
    assert_equal system_topic.id, json["system_topic_id"]

    topic_ids = json["topics"].map { |t| t["id"] }
    assert_includes topic_ids, system_topic.id,
      "active topics list must include the System topic so the sidebar can render it"
  end

  test "should create topic and broadcast" do
    assert_difference("Topic.count") do
      post collavre.creative_topics_url(@creative), params: { topic: { name: "New Strategy" } }, as: :json
    end

    assert_response :created
  end

  test "should destroy topic and broadcast" do
    assert_difference("Topic.count", -1) do
      delete collavre.creative_topic_url(@creative, @topic)
    end

    assert_response :no_content
  end

  test "destroying a selected topic advances its preference revision" do
    preference = Collavre::UserCreativePreference.create!(
      creative: @creative,
      user: @user,
      expanded_status: {},
      last_topic: @topic,
      last_topic_revision: 4
    )

    delete collavre.creative_topic_url(@creative, @topic)

    assert_response :no_content
    preference.reload
    assert_nil preference.last_topic_id
    assert_equal 5, preference.last_topic_revision
  end

  # Uses the core PreviewChannel (not the collavre_github GithubPrChannel) so
  # the core engine test suite stays independent of the optional GitHub engine
  # per AGENTS.md. The cascade-on-delete behavior under test lives in the base
  # Collavre::Channel, so any channel subclass exercises the same path.
  test "should destroy topic that has a badge channel + injected comments" do
    channel = Collavre::PreviewChannel.create!(
      topic_id: @topic.id,
      config: { "preview_url" => "http://localhost:4000", "label" => "Preview #1" }
    )
    channel.inject_into_topic!(channel.attached_message)

    assert @topic.channels.exists?, "precondition: topic has a channel (badge)"
    assert @topic.comments.exists?, "precondition: topic has injected comments"

    assert_difference("Topic.count", -1) do
      delete collavre.creative_topic_url(@creative, @topic)
    end

    assert_response :no_content
    assert_nil Collavre::Topic.find_by(id: @topic.id), "topic must actually be gone from DB"
  end

  test "should destroy topic that has a comment_snapshot (compress/merge)" do
    Collavre::CommentSnapshot.create!(
      creative: @creative,
      topic: @topic,
      user: @user,
      operation: "compress",
      comments_data: [ { "id" => 1, "content" => "x" } ]
    )

    assert Collavre::CommentSnapshot.where(topic_id: @topic.id).exists?, "precondition: topic has a snapshot"

    assert_difference("Topic.count", -1) do
      delete collavre.creative_topic_url(@creative, @topic)
    end

    assert_response :no_content
    assert_nil Collavre::Topic.find_by(id: @topic.id), "topic must actually be gone from DB"
  end

  test "should update topic name" do
    patch collavre.creative_topic_url(@creative, @topic), params: { topic: { name: "Updated Name" } }, as: :json

    assert_response :success
    @topic.reload
    assert_equal "Updated Name", @topic.name
  end

  test "should include primary_agent in update response" do
    ai_agent = User.create!(
      email: "agent-update@test.local", password: "password123", name: "UpdateAgent",
      llm_vendor: "openai", llm_model: "gpt-4", searchable: true
    )
    @topic.set_primary_agent!(ai_agent)

    patch collavre.creative_topic_url(@creative, @topic), params: { topic: { name: "Renamed" } }, as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "Renamed", json["name"]
    assert json["primary_agent"].present?, "Response must include primary_agent"
    assert_equal ai_agent.id, json["primary_agent"]["id"]
  end

  test "should not update topic without permission" do
    other_user = users(:two)
    sign_in_as other_user, password: "password"

    patch collavre.creative_topic_url(@creative, @topic), params: { topic: { name: "Hacked Name" } }, as: :json

    assert_response :forbidden
    @topic.reload
    assert_equal "Existing Topic", @topic.name
  end

  test "should reorder topics" do
    topic2 = @creative.topics.create!(name: "Topic 2", user: @user)
    topic3 = @creative.topics.create!(name: "Topic 3", user: @user)

    # Original order: @topic, topic2, topic3
    assert_equal [ @topic.id, topic2.id, topic3.id ], @creative.topics.reload.pluck(:id)

    # Reorder to: topic3, @topic, topic2
    post reorder_creative_topics_url(@creative), params: { topic_ids: [ topic3.id, @topic.id, topic2.id ] }, as: :json

    assert_response :success
    assert_equal [ topic3.id, @topic.id, topic2.id ], @creative.topics.reload.pluck(:id)
  end

  test "should not reorder topics without permission" do
    topic2 = @creative.topics.create!(name: "Topic 2", user: @user)
    other_user = users(:two)
    sign_in_as other_user, password: "password"

    post reorder_creative_topics_url(@creative), params: { topic_ids: [ topic2.id, @topic.id ] }, as: :json

    assert_response :forbidden
  end

  test "should return error for invalid topic_ids" do
    post reorder_creative_topics_url(@creative), params: { topic_ids: nil }, as: :json

    assert_response :unprocessable_entity
  end

  test "should move topic with comments to another creative" do
    target_creative = creatives(:root_parent)
    comment = Collavre::Comment.create!(creative: @creative, topic: @topic, user: @user, content: "test comment")

    patch move_creative_topic_url(@creative, @topic), params: { target_creative_id: target_creative.id }, as: :json

    assert_response :success
    @topic.reload
    comment.reload
    assert_equal target_creative.id, @topic.creative_id
    assert_equal target_creative.id, comment.creative_id, "Comment should move with topic"
  end

  test "a source changed while waiting for the move lock is forbidden" do
    target_creative = creatives(:root_parent)
    failed_move = Object.new
    failed_move.define_singleton_method(:call) do
      raise Collavre::Topics::TopicMove::SourceChangedError,
        I18n.t("collavre.topics.move.source_changed")
    end

    Collavre::Topics::TopicMove.stub(:new, ->(**) { failed_move }) do
      patch move_creative_topic_url(@creative, @topic),
        params: { target_creative_id: target_creative.id }, as: :json
    end

    assert_response :forbidden
    assert_includes JSON.parse(response.body).fetch("error"), "moved"
    assert_equal @creative.id, @topic.reload.creative_id
  end

  test "moving a topic moves its read pointers with it" do
    target_creative = creatives(:root_parent)
    comment = Collavre::Comment.create!(creative: @creative, topic: @topic, user: @user, content: "read comment")
    pointer = Collavre::CommentReadPointer.create!(
      user: @user, creative: @creative, topic: @topic, last_read_comment: comment
    )

    patch move_creative_topic_url(@creative, @topic), params: { target_creative_id: target_creative.id }, as: :json

    assert_response :success
    assert_equal target_creative.id, pointer.reload.creative_id
    assert_nil Collavre::CommentReadPointer.find_by(user: @user, creative: @creative, topic: @topic)

    patch move_creative_topic_url(target_creative, @topic), params: { target_creative_id: @creative.id }, as: :json

    assert_response :success
    assert_equal @creative.id, pointer.reload.creative_id
  end

  test "moving a topic preserves unread history for destination readers with a newer legacy cursor" do
    target_creative = Collavre::Creative.create!(user: @user, description: "Pointer target", sequence: 950)
    target_reader = users(:two)
    moved_comment = Collavre::Comment.create!(creative: @creative, topic: @topic, user: @user, content: "moved unread")
    newer_target_comment = Collavre::Comment.create!(creative: target_creative, user: @user, content: "newer target comment")
    Collavre::CreativeShare.create!(
      creative: target_creative, user: target_reader, shared_by: @user, permission: :read
    )
    Collavre::CommentReadPointer.create!(
      user: target_reader, creative: target_creative, last_read_comment: newer_target_comment
    )

    patch move_creative_topic_url(@creative, @topic), params: { target_creative_id: target_creative.id }, as: :json

    assert_response :success
    pointer = Collavre::CommentReadPointer.find_by(user: target_reader, creative: target_creative, topic: @topic)
    assert_not_nil pointer
    assert_nil pointer.last_read_comment_id
    assert_equal 1, Collavre::Creatives::CommentBadgeIndex.new(user: target_reader)
      .unread_counts_by_topic(target_creative).fetch(@topic.id)
  end

  test "moving a topic retains source-only readers' pointers with the topic" do
    target_creative = Collavre::Creative.create!(user: @user, description: "Pointer target", sequence: 951)
    source_only_reader = users(:two)
    comment = Collavre::Comment.create!(creative: @creative, topic: @topic, user: @user, content: "read comment")
    Collavre::CreativeShare.create!(
      creative: @creative, user: source_only_reader, shared_by: @user, permission: :read
    )
    pointer = Collavre::CommentReadPointer.create!(
      user: source_only_reader, creative: @creative, topic: @topic, last_read_comment: comment
    )

    patch move_creative_topic_url(@creative, @topic), params: { target_creative_id: target_creative.id }, as: :json

    assert_response :success
    assert_equal target_creative.id, pointer.reload.creative_id
    assert_empty Collavre::Comments::ReadReceiptIndex.new(
      creative: target_creative, comments: [ comment ]
    ).receipts, "the retained pointer must not reveal a receipt before target access is granted"

    @creative.destroy!
    Collavre::CreativeShare.create!(
      creative: target_creative, user: source_only_reader, shared_by: @user, permission: :read
    )

    assert_empty Collavre::Creatives::CommentBadgeIndex.new(user: source_only_reader).unread_counts_by_topic(target_creative)
  end

  test "moving a topic again retains its pointer with each destination" do
    middle_creative = Collavre::Creative.create!(user: @user, description: "Pointer middle", sequence: 952)
    target_creative = Collavre::Creative.create!(user: @user, description: "Pointer target", sequence: 953)
    source_only_reader = users(:two)
    comment = Collavre::Comment.create!(creative: @creative, topic: @topic, user: @user, content: "read comment")
    Collavre::CreativeShare.create!(
      creative: @creative, user: source_only_reader, shared_by: @user, permission: :read
    )
    pointer = Collavre::CommentReadPointer.create!(
      user: source_only_reader, creative: @creative, topic: @topic, last_read_comment: comment
    )

    patch move_creative_topic_url(@creative, @topic), params: { target_creative_id: middle_creative.id }, as: :json
    assert_response :success
    assert_equal middle_creative.id, pointer.reload.creative_id

    Collavre::CreativeShare.create!(
      creative: target_creative, user: source_only_reader, shared_by: @user, permission: :read
    )
    patch move_creative_topic_url(middle_creative, @topic), params: { target_creative_id: target_creative.id }, as: :json

    assert_response :success
    assert_equal target_creative.id, pointer.reload.creative_id
  end

  test "moving a topic keeps comments_count in sync on both creatives" do
    target_creative = creatives(:root_parent)
    Collavre::Comment.create!(creative: @creative, topic: @topic, user: @user, content: "a")
    Collavre::Comment.create!(creative: @creative, topic: @topic, user: @user, content: "b")
    source_before = @creative.reload.comments_count
    target_before = target_creative.reload.comments_count

    patch move_creative_topic_url(@creative, @topic), params: { target_creative_id: target_creative.id }, as: :json
    assert_response :success

    assert_equal source_before - 2, @creative.reload.comments_count, "source counter must drop by moved comments"
    assert_equal target_before + 2, target_creative.reload.comments_count, "target counter must rise by moved comments"
    assert_equal @creative.comments.count, @creative.comments_count, "source counter matches actual"
    assert_equal target_creative.comments.count, target_creative.comments_count, "target counter matches actual"
  end

  test "should not move topic without permission on source creative" do
    other_user = users(:two)
    sign_in_as other_user, password: "password"

    target_creative = creatives(:root_parent)

    patch move_creative_topic_url(@creative, @topic), params: { target_creative_id: target_creative.id }, as: :json

    assert_response :forbidden
  end

  test "should not move topic without write permission on target creative" do
    target_creative = creatives(:root_parent)
    target_creative.update!(user: users(:two))

    patch move_creative_topic_url(@creative, @topic), params: { target_creative_id: target_creative.id }, as: :json

    assert_response :forbidden
  end

  test "should not move topic if duplicate name exists in target" do
    target_creative = creatives(:root_parent)
    target_creative.topics.create!(name: @topic.name, user: @user)

    patch move_creative_topic_url(@creative, @topic), params: { target_creative_id: target_creative.id }, as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert json["error"].include?(@topic.name)
  end

  test "move returns members who had source access but are missing on target" do
    target_creative = creatives(:root_parent)
    shared_user = users(:two)
    Collavre::CreativeShare.create!(creative: @creative, user: shared_user, shared_by: @user, permission: :feedback)

    patch move_creative_topic_url(@creative, @topic), params: { target_creative_id: target_creative.id }, as: :json

    assert_response :success
    json = JSON.parse(response.body)
    emails = json["missing_members"].map { |m| m.dig("user", "email") }
    assert_includes emails, shared_user.email
    member = json["missing_members"].find { |m| m.dig("user", "email") == shared_user.email }
    assert_equal "feedback", member["permission"]
    assert_equal target_creative.creative_snippet, json["target_creative_name"]
  end

  test "move returns no missing members when target already has them" do
    target_creative = creatives(:root_parent)
    shared_user = users(:two)
    Collavre::CreativeShare.create!(creative: @creative, user: shared_user, shared_by: @user, permission: :feedback)
    Collavre::CreativeShare.create!(creative: target_creative, user: shared_user, shared_by: @user, permission: :read)

    patch move_creative_topic_url(@creative, @topic), params: { target_creative_id: target_creative.id }, as: :json

    assert_response :success
    json = JSON.parse(response.body)
    emails = json["missing_members"].map { |m| m.dig("user", "email") }
    assert_not_includes emails, shared_user.email
  end

  test "move omits missing members when mover lacks admin on target" do
    target_creative = creatives(:root_parent)
    target_creative.update!(user: users(:two))
    # Give the mover write (so the move is allowed) but not admin on the target.
    Collavre::CreativeShare.create!(creative: target_creative, user: @user, shared_by: users(:two), permission: :write)
    # A source member who is missing on the target.
    Collavre::CreativeShare.create!(creative: @creative, user: users(:three), shared_by: @user, permission: :feedback)

    patch move_creative_topic_url(@creative, @topic), params: { target_creative_id: target_creative.id }, as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_empty json["missing_members"]
  end

  # The pin travels with the topic, and it is exclusive: if the agent has no
  # feedback access at the destination, Matcher#match_by_primary_agent returns []
  # and the moved topic can route to nobody at all. Release it instead so the
  # topic falls back to ordinary expression routing there.
  test "move releases a primary agent that cannot respond on the target" do
    target_creative = creatives(:root_parent)
    agent = move_test_agent("moveagent@test.local", "MoveAgent")
    Collavre::CreativeShare.create!(creative: @creative, user: agent, shared_by: @user, permission: :feedback)
    @topic.set_primary_agent!(agent)

    patch move_creative_topic_url(@creative, @topic), params: { target_creative_id: target_creative.id }, as: :json

    assert_response :success
    assert_nil @topic.reload.primary_agent_id, "an unanswerable pin must not survive the move"
    json = JSON.parse(response.body)
    assert_equal agent.id, json.dig("released_primary_agent", "id")
    assert json.dig("released_primary_agent", "message").present?,
           "the release must be reported so it is not silent"
  end

  # The release has two possible causes now, and the advice differs. A Claude
  # Channel session agent holds inbox-wide :feedback, so moving its topic into
  # the inbox passes the permission check while Matcher#eligible_in_inbox? still
  # refuses to route it anywhere but its own session topic. Reporting the
  # permission message here would tell the user to share a creative the agent is
  # already shared on — advice that cannot fix anything.
  test "move reports session confinement, not missing access, when releasing a session agent" do
    inbox = Collavre::Creative.inbox_for(@user)
    agent = move_test_agent("sessionmove@test.local", "SessionMoveAgent")
    agent.update!(llm_vendor: "anthropic", llm_model: "claude-code")
    Collavre::CreativeShare.create!(creative: @creative, user: agent, shared_by: @user, permission: :feedback)
    Collavre::CreativeShare.create!(creative: inbox, user: agent, shared_by: @user, permission: :feedback)
    @topic.set_primary_agent!(agent)

    patch move_creative_topic_url(@creative, @topic), params: { target_creative_id: inbox.id }, as: :json

    assert_response :success
    assert_nil @topic.reload.primary_agent_id,
               "a session agent cannot be routed to on an ordinary inbox topic, so the pin must not survive"
    message = JSON.parse(response.body).dig("released_primary_agent", "message")
    assert_equal I18n.t("collavre.topics.move.primary_agent_released_session_agent",
                        agent: agent.display_name, creative: inbox.creative_snippet),
                 message
    refute_equal I18n.t("collavre.topics.move.primary_agent_released",
                        agent: agent.display_name, creative: inbox.creative_snippet),
                 message,
                 "the agent already has feedback access here — telling the user to share would be unfollowable"
  end

  test "move keeps a primary agent that still has feedback access on the target" do
    target_creative = creatives(:root_parent)
    agent = move_test_agent("stayagent@test.local", "StayAgent")
    Collavre::CreativeShare.create!(creative: @creative, user: agent, shared_by: @user, permission: :feedback)
    Collavre::CreativeShare.create!(creative: target_creative, user: agent, shared_by: @user, permission: :feedback)
    @topic.set_primary_agent!(agent)

    patch move_creative_topic_url(@creative, @topic), params: { target_creative_id: target_creative.id }, as: :json

    assert_response :success
    assert_equal agent.id, @topic.reload.primary_agent_id, "a valid assignment must survive the move"
    assert_nil JSON.parse(response.body)["released_primary_agent"]
  end

  # A session topic's pin is identity, not routing: SessionProvisioner reuses it
  # via inbox.topics.find_by(primary_agent_id:, session_id:). Moving it out of
  # the inbox would fork a second topic on the next registration, so the whole
  # move is refused rather than releasing the pin.
  test "should not move a Claude Channel session topic" do
    target_creative = creatives(:root_parent)
    agent = move_test_agent("sessionagent@test.local", "SessionAgent")
    Collavre::CreativeShare.create!(creative: @creative, user: agent, shared_by: @user, permission: :feedback)
    @topic.update!(session_id: "sess-move-1")
    @topic.set_primary_agent!(agent)

    patch move_creative_topic_url(@creative, @topic), params: { target_creative_id: target_creative.id }, as: :json

    assert_response :unprocessable_entity
    @topic.reload
    assert_equal @creative.id, @topic.creative_id, "the session topic must stay put"
    assert_equal agent.id, @topic.primary_agent_id
  end

  test "should set primary agent on topic" do
    ai_agent = User.create!(
      email: "agent@test.local", password: "password123", name: "TestAgent",
      llm_vendor: "openai", llm_model: "gpt-4", searchable: true
    )
    Collavre::CreativeShare.create!(creative: @creative, user: ai_agent, shared_by: @user, permission: :feedback)

    patch set_primary_agent_creative_topic_url(@creative, @topic),
      params: { agent_id: ai_agent.id }, as: :json

    assert_response :success
    @topic.reload
    assert_equal ai_agent.id, @topic.primary_agent_id
  end

  test "should replace existing primary agent" do
    old_agent = User.create!(
      email: "old@test.local", password: "password123", name: "OldAgent",
      llm_vendor: "openai", llm_model: "gpt-4", searchable: true
    )
    new_agent = User.create!(
      email: "new@test.local", password: "password123", name: "NewAgent",
      llm_vendor: "openai", llm_model: "gpt-4", searchable: true
    )
    Collavre::CreativeShare.create!(creative: @creative, user: new_agent, shared_by: @user, permission: :feedback)
    @topic.set_primary_agent!(old_agent)

    patch set_primary_agent_creative_topic_url(@creative, @topic),
      params: { agent_id: new_agent.id }, as: :json

    assert_response :success
    @topic.reload
    assert_equal new_agent.id, @topic.primary_agent_id
  end

  test "should clear primary agent when agent_id is blank" do
    ai_agent = User.create!(
      email: "clearme@test.local", password: "password123", name: "ClearAgent",
      llm_vendor: "openai", llm_model: "gpt-4", searchable: true
    )
    @topic.set_primary_agent!(ai_agent)

    patch set_primary_agent_creative_topic_url(@creative, @topic),
      params: { agent_id: nil }, as: :json

    assert_response :success
    @topic.reload
    assert_nil @topic.primary_agent_id

    body = JSON.parse(response.body)
    # The client merges this payload into its cached topic, so the key must be
    # present-and-null to actually remove the avatar.
    assert body["topic"].key?("primary_agent")
    assert_nil body["topic"]["primary_agent"]
  end

  # On a session topic primary_agent_id is session identity, not a routing pin:
  # clearing it makes the live session unroutable and makes the next registration
  # create a second topic instead of reusing the conversation.
  test "should refuse to clear the primary agent of a session topic" do
    ai_agent = User.create!(
      email: "sessionagent@test.local", password: "password123", name: "SessionAgent",
      llm_vendor: "anthropic", llm_model: "claude", searchable: true
    )
    @topic.set_primary_agent!(ai_agent)
    @topic.update!(session_id: "sess-abc123")

    patch set_primary_agent_creative_topic_url(@creative, @topic),
      params: { agent_id: nil }, as: :json

    assert_response :unprocessable_entity
    assert_equal ai_agent.id, @topic.reload.primary_agent_id
  end

  test "should refuse to reassign the primary agent of a session topic" do
    ai_agent = User.create!(
      email: "sessionagent2@test.local", password: "password123", name: "SessionAgent2",
      llm_vendor: "anthropic", llm_model: "claude", searchable: true
    )
    other_agent = User.create!(
      email: "otheragent@test.local", password: "password123", name: "OtherAgent",
      llm_vendor: "openai", llm_model: "gpt-4", searchable: true
    )
    @topic.set_primary_agent!(ai_agent)
    @topic.update!(session_id: "sess-def456")

    patch set_primary_agent_creative_topic_url(@creative, @topic),
      params: { agent_id: other_agent.id }, as: :json

    assert_response :unprocessable_entity
    assert_equal ai_agent.id, @topic.reload.primary_agent_id
  end

  test "should reject non-AI user as primary agent" do
    patch set_primary_agent_creative_topic_url(@creative, @topic),
      params: { agent_id: @user.id }, as: :json

    assert_response :unprocessable_entity
  end

  test "should reject invalid agent_id" do
    patch set_primary_agent_creative_topic_url(@creative, @topic),
      params: { agent_id: 999999 }, as: :json

    assert_response :unprocessable_entity
  end

  # A searchable agent is offered by the palette (and by User.mentionable_for)
  # even with no share here. Pinning one would make the topic mute: the pin
  # excludes every other agent's ambient routing while the pinned agent itself
  # fails Matcher#has_creative_permission? and cannot answer.
  test "should reject a primary agent that has no feedback access on the creative" do
    outsider = User.create!(
      email: "outsider@test.local", password: "password123", name: "Outsider",
      llm_vendor: "openai", llm_model: "gpt-4", searchable: true
    )

    patch set_primary_agent_creative_topic_url(@creative, @topic),
      params: { agent_id: outsider.id }, as: :json

    assert_response :unprocessable_entity
    assert_nil @topic.reload.primary_agent_id
  end

  test "should reject moving a pin onto an agent without feedback access" do
    shared_agent = User.create!(
      email: "shared-agent@test.local", password: "password123", name: "SharedAgent",
      llm_vendor: "openai", llm_model: "gpt-4", searchable: true
    )
    Collavre::CreativeShare.create!(creative: @creative, user: shared_agent, shared_by: @user, permission: :feedback)
    outsider = User.create!(
      email: "outsider2@test.local", password: "password123", name: "Outsider2",
      llm_vendor: "openai", llm_model: "gpt-4", searchable: true
    )
    @topic.set_primary_agent!(shared_agent)

    patch set_primary_agent_creative_topic_url(@creative, @topic),
      params: { agent_id: outsider.id }, as: :json

    assert_response :unprocessable_entity
    assert_equal shared_agent.id, @topic.reload.primary_agent_id
  end

  test "should reject creating a topic pinned to an agent without feedback access" do
    outsider = User.create!(
      email: "outsider3@test.local", password: "password123", name: "Outsider3",
      llm_vendor: "openai", llm_model: "gpt-4", searchable: true
    )

    assert_no_difference("Topic.count") do
      post collavre.creative_topics_url(@creative),
        params: { topic: { name: "Talk to Outsider3" }, agent_id: outsider.id }, as: :json
    end

    assert_response :unprocessable_entity
  end

  # An agent shared only on an ancestor still resolves through the permission
  # cascade, so it must stay assignable — the guard has to be the routing
  # predicate, not a direct-share lookup.
  test "should accept a primary agent whose feedback access is inherited" do
    child = Collavre::Creative.create!(user: @user, parent: @creative, description: "Child")
    child_topic = child.topics.create!(name: "Child Topic", user: @user)
    ai_agent = User.create!(
      email: "inherited@test.local", password: "password123", name: "InheritedAgent",
      llm_vendor: "openai", llm_model: "gpt-4", searchable: true
    )
    Collavre::CreativeShare.create!(creative: @creative, user: ai_agent, shared_by: @user, permission: :feedback)

    patch set_primary_agent_creative_topic_url(child, child_topic),
      params: { agent_id: ai_agent.id }, as: :json

    assert_response :success
    assert_equal ai_agent.id, child_topic.reload.primary_agent_id
  end

  # Registration grants a Claude Channel agent inbox-wide :feedback, so the
  # permission check alone passes on every inbox topic — but
  # Matcher#eligible_in_inbox? confines it to the topic carrying its session_id.
  # Pinning it on an ordinary inbox topic would make match_by_primary_agent
  # return [] and mute the topic for everyone.
  test "should reject a Claude Channel session agent on an ordinary inbox topic" do
    inbox = Collavre::Creative.inbox_for(@user)
    inbox_topic = inbox.topics.create!(name: "Ordinary Inbox Topic", user: @user)
    session_agent = User.create!(
      email: "cc-session@test.local", password: "password123", name: "Claude Channel (dev)",
      llm_vendor: "anthropic", llm_model: "claude-code", searchable: false, created_by_id: @user.id
    )
    Collavre::CreativeShare.create!(creative: inbox, user: session_agent, shared_by: @user, permission: :feedback)

    patch set_primary_agent_creative_topic_url(inbox, inbox_topic),
      params: { agent_id: session_agent.id }, as: :json

    assert_response :unprocessable_entity
    assert_nil inbox_topic.reload.primary_agent_id
    assert_equal I18n.t("collavre.topics.session_agent_not_assignable", name: session_agent.display_name),
      JSON.parse(response.body)["error"],
      "the message must name the session rule, not claim the agent lacks access"
  end

  test "should reject creating an inbox topic pinned to a Claude Channel session agent" do
    inbox = Collavre::Creative.inbox_for(@user)
    session_agent = User.create!(
      email: "cc-session-create@test.local", password: "password123", name: "Claude Channel (create)",
      llm_vendor: "anthropic", llm_model: "claude-code", searchable: false, created_by_id: @user.id
    )
    Collavre::CreativeShare.create!(creative: inbox, user: session_agent, shared_by: @user, permission: :feedback)

    assert_no_difference("Topic.count") do
      post collavre.creative_topics_url(inbox),
        params: { topic: { name: "Talk to session" }, agent_id: session_agent.id }, as: :json
    end

    assert_response :unprocessable_entity
  end

  # Negative control: the confinement is inbox-only. On an ordinary creative
  # Matcher routes a Claude Channel agent by routing_expression like any other,
  # so rejecting it there would break a legitimate assignment.
  test "should accept a Claude Channel session agent outside the inbox" do
    session_agent = User.create!(
      email: "cc-session-work@test.local", password: "password123", name: "Claude Channel (work)",
      llm_vendor: "anthropic", llm_model: "claude-code", searchable: false, created_by_id: @user.id
    )
    Collavre::CreativeShare.create!(creative: @creative, user: session_agent, shared_by: @user, permission: :feedback)

    patch set_primary_agent_creative_topic_url(@creative, @topic),
      params: { agent_id: session_agent.id }, as: :json

    assert_response :success
    assert_equal session_agent.id, @topic.reload.primary_agent_id
  end

  test "should create topic with agent_id" do
    ai_agent = User.create!(
      email: "agent2@test.local", password: "password123", name: "Agent2",
      llm_vendor: "openai", llm_model: "gpt-4", searchable: true
    )
    Collavre::CreativeShare.create!(creative: @creative, user: ai_agent, shared_by: @user, permission: :feedback)

    assert_difference("Topic.count") do
      post collavre.creative_topics_url(@creative),
        params: { topic: { name: "Talk to Agent2" }, agent_id: ai_agent.id }, as: :json
    end

    assert_response :created
    topic = @creative.topics.find_by(name: "Talk to Agent2")
    assert topic.present?
    assert_equal ai_agent.id, topic.primary_agent_id
  end

  test "should create topic with comment_ids and move comments" do
    comment1 = Collavre::Comment.create!(creative: @creative, user: @user, content: "Message 1")
    comment2 = Collavre::Comment.create!(creative: @creative, user: @user, content: "Message 2")

    assert_difference("Topic.count") do
      post collavre.creative_topics_url(@creative),
        params: { topic: { name: "New Thread" }, comment_ids: [ comment1.id, comment2.id ] }, as: :json
    end

    assert_response :created
    topic = @creative.topics.find_by(name: "New Thread")
    assert topic.present?

    comment1.reload
    comment2.reload
    assert_equal topic.id, comment1.topic_id
    assert_equal topic.id, comment2.topic_id
  end

  test "should return next_name for auto-generated topic name" do
    get next_name_creative_topics_url(@creative), as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert json["name"].present?
    # First auto-name should be "Topic1" (en locale)
    assert_match(/\A.+1\z/, json["name"])
  end

  test "next_name should increment based on existing topics" do
    @creative.topics.create!(name: "Topic1", user: @user)
    @creative.topics.create!(name: "Topic3", user: @user)

    get next_name_creative_topics_url(@creative), as: :json

    assert_response :success
    json = JSON.parse(response.body)
    # Should return Topic4 (max existing is 3, so 3+1=4)
    assert_match(/4\z/, json["name"])
  end

  test "new topic should be created at the end after reordering" do
    # Create initial topics
    topic2 = @creative.topics.create!(name: "Topic 2", user: @user)
    topic3 = @creative.topics.create!(name: "Topic 3", user: @user)

    # Verify initial order: @topic(0), topic2(1), topic3(2)
    assert_equal [ @topic.id, topic2.id, topic3.id ], @creative.topics.reload.pluck(:id)

    # Reorder to: topic3(0), @topic(1), topic2(2)
    post reorder_creative_topics_url(@creative), params: { topic_ids: [ topic3.id, @topic.id, topic2.id ] }, as: :json
    assert_response :success

    # Create a new topic - should be at the end (position 3)
    post collavre.creative_topics_url(@creative), params: { topic: { name: "New Topic" } }, as: :json
    assert_response :created

    new_topic = @creative.topics.find_by(name: "New Topic")

    # Verify new topic is at the end
    assert_equal [ topic3.id, @topic.id, topic2.id, new_topic.id ], @creative.topics.reload.pluck(:id)
    assert_equal 3, new_topic.position
  end

  private

  def move_test_agent(email, name)
    User.create!(
      email: email, password: "password123", name: name,
      llm_vendor: "openai", llm_model: "gpt-4", searchable: true
    )
  end
end
