require "test_helper"

class PublicCreativeLayoutTest < ActionDispatch::IntegrationTest
  test "anonymous creative pages retain the constrained layout" do
    get collavre.creatives_path

    assert_response :success
    assert_select "main"
    assert_select "main.public-creative-main", count: 0
    assert_select ".creative-workspace-shell", count: 0
  end

  test "anonymous public detail pages retain the constrained layout" do
    creative = Creative.create!(user: users(:one), description: "Public document")
    perform_enqueued_jobs { CreativeShare.create!(creative: creative, user: nil, permission: :read) }
    get collavre.public_creative_path(public_id: creative.ensure_public_id!, slug: creative.public_slug)

    assert_response :success
    assert_select "main"
    assert_select "main.public-creative-main", count: 0
  end

  test "sign in pages retain the constrained layout" do
    get collavre.new_session_path

    assert_response :success
    assert_select "main.public-creative-main", count: 0
  end

  test "signed in creative pages retain the workspace layout" do
    users(:one).update!(creative_workspace_enabled: true)
    sign_in_as(users(:one), password: "password")

    get collavre.creatives_path

    assert_response :success
    assert_select ".creative-workspace-shell > main"
    assert_select "main.public-creative-main", count: 0
  end
end
