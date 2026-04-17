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
