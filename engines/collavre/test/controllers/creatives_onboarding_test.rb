require "test_helper"

class CreativesOnboardingTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:two)
    @user.update!(onboarding_seeded_at: nil, onboarding_completed_at: nil)
    Creative.onboarding_guides.where(user: @user).destroy_all
    Creative.inbox_for(@user)
    sign_in_as(@user, password: "password")
  end

  test "first root HTML visit seeds onboarding and opens the guide" do
    assert_difference -> { Creative.count }, 6 do
      get collavre.creatives_path
    end

    guide = Creative.onboarding_guides.find_by!(user: @user)
    assert_redirected_to collavre.creatives_path(id: guide.id)

    assert_no_difference -> { Creative.count } do
      follow_redirect!
    end
    assert_response :success
  end

  test "returning to the root does not seed onboarding again" do
    @user.update!(onboarding_seeded_at: Time.current)

    assert_no_difference -> { Creative.count } do
      get collavre.creatives_path
    end

    assert_response :success
  end

  test "direct creative visit does not seed onboarding" do
    creative = creatives(:root_parent)

    assert_no_difference -> { Creative.count } do
      get collavre.creatives_path(id: creative.id)
    end

    assert_response :success
    assert_nil @user.reload.onboarding_seeded_at
  end

  test "root JSON visit seeds onboarding without redirecting" do
    assert_difference -> { Creative.count }, 6 do
      get collavre.creatives_path(format: :json)
    end

    assert_response :success
    assert_not_nil @user.reload.onboarding_seeded_at
  end

  test "seeding failure does not block the workspace" do
    Collavre::Onboarding::Seeder.stub(:call, nil) do
      get collavre.creatives_path
    end

    assert_response :success
  end

  test "create then edit requests complete the create-edit card" do
    get collavre.creatives_path
    guide = Creative.onboarding_guides.find_by!(user: @user)
    card = guide.children.find { |creative| creative.onboarding_metadata["step_key"] == "create_edit" }

    post collavre.creatives_path,
         params: { creative: { parent_id: card.id, description: "Draft" } },
         as: :json
    assert_response :success
    practice = Creative.find(response.parsed_body["id"])
    assert_equal card.id, response.parsed_body["onboarding_card_id"]
    assert_equal guide.id, response.parsed_body["onboarding_root_id"]
    assert_equal "in_progress", card.reload.onboarding_metadata["status"]

    patch collavre.creative_path(practice),
          params: { creative: { description: "Edited draft" } },
          as: :json

    assert_response :success
    assert_equal card.id, response.parsed_body["onboarding_card_id"]
    assert_equal guide.id, response.parsed_body["onboarding_root_id"]
    assert_equal "completed", card.reload.onboarding_metadata["status"]
  end


  test "create rejects a parent the current user cannot write" do
    owner = users(:one)
    owner.update!(onboarding_seeded_at: nil, onboarding_completed_at: nil)
    Creative.inbox_for(owner)
    guide = Collavre::Onboarding::Seeder.call(user: owner)
    card = guide.children.find { |creative| creative.onboarding_metadata["step_key"] == "create_edit" }

    perform_enqueued_jobs do
      CreativeShare.create!(creative: guide, user: @user, permission: :read, shared_by: owner)
    end

    assert_no_difference -> { Creative.count } do
      post collavre.creatives_path,
           params: { creative: { parent_id: card.id, description: "Unauthorized child" } },
           as: :json
    end

    assert_response :unprocessable_entity
    assert_includes response.parsed_body["errors"], I18n.t("collavre.creatives.errors.parent_no_write_permission")
  end

  test "progress update request completes the real progress practice" do
    get collavre.creatives_path
    guide = Creative.onboarding_guides.find_by!(user: @user)
    card = guide.children.find { |creative| creative.onboarding_metadata["step_key"] == "progress_rollup" }
    practice = card.children.sole

    patch collavre.creative_path(practice), params: { creative: { progress: 1 } }, as: :json

    assert_response :success
    assert_equal card.id, response.parsed_body["onboarding_card_id"]
    assert_equal guide.id, response.parsed_body["onboarding_root_id"]
    assert_equal "completed", card.reload.onboarding_metadata["status"]
  end

  test "archive request cannot strand an active onboarding item" do
    get collavre.creatives_path
    guide = Creative.onboarding_guides.find_by!(user: @user)
    practice = guide.descendants.find(&:onboarding_practice?)

    get collavre.creatives_path(id: practice.id)
    assert_select "creative-tree-row[is-title][onboarding-item]"

    patch collavre.archive_creative_path(practice)

    assert_response :unprocessable_entity
    assert_not practice.reload.archived?
  end

  test "onboarding cards use server-rendered feature cards with static API fallback data" do
    get collavre.creatives_path
    guide = Creative.onboarding_guides.find_by!(user: @user)
    card = guide.children.find { |creative| creative.onboarding_metadata["step_key"] == "create_edit" }

    get collavre.creative_path(card), as: :json

    assert_response :success
    assert_includes response.parsed_body["description"], "feature-card--onboarding"
    assert_includes response.parsed_body["description"], "add-creative-btn"
    assert_includes response.parsed_body["description_raw_html"], "<p>"
    assert_not_includes response.parsed_body["description_raw_html"], "<button"
    assert_equal "onboarding", response.parsed_body.dig("data", "source", "type")
  end

  test "inline create form preserves the engine mount prefix" do
    creative = creatives(:root_parent)

    get collavre.creatives_path(id: creative.id), env: { "SCRIPT_NAME" => "/collavre" }

    assert_response :success
    mounted_create_path = collavre.creatives_path(script_name: "/collavre")
    assert_select "form#inline-edit-form-element[action=?][data-create-url=?]", mounted_create_path, mounted_create_path
  end
end
