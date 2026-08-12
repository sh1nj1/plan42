require "test_helper"

class CreativeSharesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:one)
    @creative = creatives(:tshirt)
    @target_user = users(:three)
  end

  test "creating a share adds the target to contacts" do
    sign_in_as(@owner, password: "password")

    assert_difference([ "CreativeShare.count", "Contact.count" ], 1) do
      post collavre.creative_creative_shares_path(@creative), params: { user_email: @target_user.email, permission: :read }
    end

    assert Contact.exists?(user: @owner, contact_user: @target_user)
  end

  test "granting destination access restores a pointer stranded by a topic move" do
    source = Collavre::Creative.create!(user: @owner, description: "Pointer source", sequence: 811)
    topic = source.topics.create!(name: "Moved topic", user: @owner)
    comment = Collavre::Comment.create!(creative: source, topic: topic, user: @owner, content: "read comment")
    Collavre::CreativeShare.create!(creative: source, user: @target_user, shared_by: @owner, permission: :read)
    pointer = Collavre::CommentReadPointer.create!(
      user: @target_user, creative: source, topic: topic, last_read_comment: comment
    )

    sign_in_as(@owner, password: "password")
    patch move_creative_topic_url(source, topic), params: { target_creative_id: @creative.id }, as: :json

    assert_response :success
    assert_equal source.id, pointer.reload.creative_id

    post collavre.creative_creative_shares_path(@creative),
      params: { user_email: @target_user.email, permission: :read }, as: :json

    assert_response :created
    assert_equal @creative.id, pointer.reload.creative_id
  end

  test "removing a destination no_access share restores a pointer stranded by a topic move" do
    source = Collavre::Creative.create!(user: @owner, description: "Pointer source")
    destination_parent = Collavre::Creative.create!(user: @owner, description: "Pointer destination parent")
    destination = Collavre::Creative.create!(
      user: @owner, parent: destination_parent, description: "Pointer destination"
    )
    topic = source.topics.create!(name: "Moved topic", user: @owner)
    comment = Collavre::Comment.create!(creative: source, topic: topic, user: @owner, content: "read comment")
    pointer = Collavre::CommentReadPointer.create!(
      user: @target_user, creative: source, topic: topic, last_read_comment: comment
    )

    blocked_share = nil
    perform_enqueued_jobs do
      Collavre::CreativeShare.create!(creative: source, user: @target_user, shared_by: @owner, permission: :read)
      Collavre::CreativeShare.create!(
        creative: destination_parent, user: @target_user, shared_by: @owner, permission: :read
      )
      blocked_share = Collavre::CreativeShare.create!(
        creative: destination, user: @target_user, shared_by: @owner, permission: :no_access
      )
    end

    refute destination.has_permission?(@target_user, :read)

    sign_in_as(@owner, password: "password")
    patch move_creative_topic_url(source, topic), params: { target_creative_id: destination.id }, as: :json

    assert_response :success
    assert_equal source.id, pointer.reload.creative_id

    perform_enqueued_jobs { blocked_share.destroy! }

    assert destination.reload.has_permission?(@target_user, :read)
    assert_equal destination.id, pointer.reload.creative_id
  end

  test "a public ancestor grant restores pointers stranded on descendant topics" do
    source = Collavre::Creative.create!(user: @owner, description: "Pointer source")
    destination_parent = Collavre::Creative.create!(user: @owner, description: "Pointer destination parent")
    destination = Collavre::Creative.create!(user: @owner, parent: destination_parent, description: "Pointer destination")
    topic = source.topics.create!(name: "Moved topic", user: @owner)
    comment = Collavre::Comment.create!(creative: source, topic: topic, user: @owner, content: "read comment")
    Collavre::CreativeShare.create!(creative: source, user: @target_user, shared_by: @owner, permission: :read)
    pointer = Collavre::CommentReadPointer.create!(
      user: @target_user, creative: source, topic: topic, last_read_comment: comment
    )

    sign_in_as(@owner, password: "password")
    patch move_creative_topic_url(source, topic), params: { target_creative_id: destination.id }, as: :json

    assert_response :success
    assert_equal source.id, pointer.reload.creative_id

    Collavre::CreativeShare.create!(creative: destination_parent, user: nil, permission: :read)

    assert_equal destination.id, pointer.reload.creative_id
  end

  test "an inherited named grant restores pointers stranded on descendant topics" do
    source = Collavre::Creative.create!(user: @owner, description: "Pointer source")
    destination_parent = Collavre::Creative.create!(user: @owner, description: "Pointer destination parent")
    destination = Collavre::Creative.create!(user: @owner, parent: destination_parent, description: "Pointer destination")
    topic = source.topics.create!(name: "Moved topic", user: @owner)
    comment = Collavre::Comment.create!(creative: source, topic: topic, user: @owner, content: "read comment")
    Collavre::CreativeShare.create!(creative: source, user: @target_user, shared_by: @owner, permission: :read)
    pointer = Collavre::CommentReadPointer.create!(
      user: @target_user, creative: source, topic: topic, last_read_comment: comment
    )

    sign_in_as(@owner, password: "password")
    patch move_creative_topic_url(source, topic), params: { target_creative_id: destination.id }, as: :json

    assert_response :success
    assert_equal source.id, pointer.reload.creative_id

    Collavre::CreativeShare.create!(
      creative: destination_parent, user: @target_user, shared_by: @owner, permission: :read
    )

    assert_equal destination.id, pointer.reload.creative_id
  end

  test "revoking destination access removes its topic read pointer" do
    source = Collavre::Creative.create!(user: @owner, description: "Pointer source")
    destination = Collavre::Creative.create!(user: @owner, description: "Pointer destination")
    topic = source.topics.create!(name: "Moved topic", user: @owner)
    comment = Collavre::Comment.create!(creative: source, topic: topic, user: @owner, content: "read comment")
    Collavre::CreativeShare.create!(creative: source, user: @target_user, shared_by: @owner, permission: :read)
    destination_share = nil
    perform_enqueued_jobs do
      destination_share = Collavre::CreativeShare.create!(
        creative: destination, user: @target_user, shared_by: @owner, permission: :read
      )
    end
    pointer = Collavre::CommentReadPointer.create!(
      user: @target_user, creative: source, topic: topic, last_read_comment: comment
    )

    sign_in_as(@owner, password: "password")
    patch move_creative_topic_url(source, topic), params: { target_creative_id: destination.id }, as: :json

    assert_response :success
    assert_equal destination.id, pointer.reload.creative_id

    destination_share.update!(permission: :no_access)

    assert_nil Collavre::CommentReadPointer.find_by(id: pointer.id)
  end

  test "removing destination access removes its topic read pointer" do
    source = Collavre::Creative.create!(user: @owner, description: "Pointer source")
    destination = Collavre::Creative.create!(user: @owner, description: "Pointer destination")
    topic = source.topics.create!(name: "Moved topic", user: @owner)
    comment = Collavre::Comment.create!(creative: source, topic: topic, user: @owner, content: "read comment")
    Collavre::CreativeShare.create!(creative: source, user: @target_user, shared_by: @owner, permission: :read)
    destination_share = nil
    perform_enqueued_jobs do
      destination_share = Collavre::CreativeShare.create!(
        creative: destination, user: @target_user, shared_by: @owner, permission: :read
      )
    end
    pointer = Collavre::CommentReadPointer.create!(
      user: @target_user, creative: source, topic: topic, last_read_comment: comment
    )

    sign_in_as(@owner, password: "password")
    patch move_creative_topic_url(source, topic), params: { target_creative_id: destination.id }, as: :json

    assert_response :success
    assert_equal destination.id, pointer.reload.creative_id

    destination_share.destroy!

    assert_nil Collavre::CommentReadPointer.find_by(id: pointer.id)
  end

  test "non-owner cannot share non-searchable AI agent" do
    # Create a non-searchable AI agent owned by @owner
    ai_agent = User.create!(
      email: "private-ai@ai.local",
      password: "password123",
      name: "Private AI",
      llm_vendor: "openai",
      searchable: false,
      created_by_id: @owner.id
    )

    # @target_user tries to share the AI agent to their own creative
    other_user = users(:two)
    other_creative = Collavre::Creative.create!(user: other_user, description: "Other's creative")

    sign_in_as(other_user, password: "password")

    assert_no_difference("Collavre::CreativeShare.count") do
      post collavre.creative_creative_shares_path(other_creative), params: { user_email: ai_agent.email, permission: :feedback }
    end

    assert_match I18n.t("collavre.creatives.share.cannot_share_private_ai_agent"), flash[:alert]
  end

  test "owner can share non-searchable AI agent" do
    # Create a non-searchable AI agent owned by @owner
    ai_agent = User.create!(
      email: "owner-private-ai@ai.local",
      password: "password123",
      name: "Owner's Private AI",
      llm_vendor: "openai",
      searchable: false,
      created_by_id: @owner.id
    )

    sign_in_as(@owner, password: "password")

    assert_difference("Collavre::CreativeShare.count", 1) do
      post collavre.creative_creative_shares_path(@creative), params: { user_email: ai_agent.email, permission: :feedback }
    end

    assert_equal I18n.t("collavre.creatives.share.shared"), flash[:notice]
  end

  test "non-admin user gets 404 (not 403) when updating someone else's share" do
    other_user = users(:two)
    share = CreativeShare.create!(creative: @creative, user: @target_user, permission: :read, shared_by: @owner)

    sign_in_as(other_user, password: "password")

    patch collavre.creative_creative_share_path(@creative, share), params: { permission: :write }, as: :json

    assert_response :not_found
    assert_equal "read", share.reload.permission
  end

  test "non-admin user gets 404 (not 403) when destroying someone else's share" do
    other_user = users(:two)
    share = CreativeShare.create!(creative: @creative, user: @target_user, permission: :read, shared_by: @owner)

    sign_in_as(other_user, password: "password")

    assert_no_difference("CreativeShare.count") do
      delete collavre.creative_creative_share_path(@creative, share), as: :json
    end

    assert_response :not_found
  end

  test "anyone can share searchable AI agent" do
    # Create a searchable AI agent owned by @owner
    ai_agent = User.create!(
      email: "public-ai@ai.local",
      password: "password123",
      name: "Public AI",
      llm_vendor: "openai",
      searchable: true,
      created_by_id: @owner.id
    )

    # @target_user (non-owner) shares the searchable AI agent
    other_user = users(:two)
    other_creative = Collavre::Creative.create!(user: other_user, description: "Other's creative for public AI")

    sign_in_as(other_user, password: "password")

    assert_difference("Collavre::CreativeShare.count", 1) do
      post collavre.creative_creative_shares_path(other_creative), params: { user_email: ai_agent.email, permission: :feedback }
    end

    assert_equal I18n.t("collavre.creatives.share.shared"), flash[:notice]
  end
end
