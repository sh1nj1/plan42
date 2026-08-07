require "test_helper"

class CreativesControllerEmptyStateTest < ActionDispatch::IntegrationTest
  # The HTML branch of CreativesController#index always renders with
  # @creatives = [] (real data streams in via a separate JSON fetch), so the
  # empty-state markup built in index.html.erb is present on every initial
  # HTML page load regardless of whether the tree actually has children.

  # Translations are rendered through `<%= t(...) %>`, so HTML-sensitive
  # characters (e.g. the apostrophe in "What's a creative?") come back
  # entity-escaped in the response body.
  def html_t(key)
    ERB::Util.html_escape(I18n.t(key))
  end

  test "root empty state shows writable CTAs for an authenticated user" do
    sign_in_as(users(:one), password: "password")

    get creatives_path

    assert_response :success
    assert_includes response.body, html_t("collavre.creatives.index.empty_state_heading_root")
    assert_includes response.body, html_t("collavre.creatives.index.empty_state_concept_title")
    assert_match(/class="[^"]*\bnew-root-creative-btn\b[^"]*"/, response.body)
    assert_includes response.body, html_t("collavre.creatives.index.empty_state_add_creative")
    assert_includes response.body, 'data-action="click->creatives--import#toggle"'
    assert_includes response.body, html_t("collavre.creatives.index.import_markdown")
    refute_includes response.body, html_t("collavre.creatives.index.empty_state_readonly_message")
  end

  test "nested empty state shows writable CTAs when the user has write permission" do
    creative = creatives(:childless_creative)
    sign_in_as(users(:one), password: "password")

    get creatives_path(id: creative.id)

    assert_response :success
    assert_includes response.body, html_t("collavre.creatives.index.empty_state_heading_sub")
    assert_match(/class="[^"]*\badd-creative-btn--cta\b[^"]*"[^>]*data-parent-id="#{creative.id}"/, response.body)
    assert_includes response.body, html_t("collavre.creatives.index.empty_state_add_sub_creative")
    assert_includes response.body, html_t("collavre.creatives.index.import_markdown")
    refute_includes response.body, html_t("collavre.creatives.index.empty_state_readonly_message")
  end

  test "nested empty state shows the write-access request CTA when the user only has read permission" do
    creative = creatives(:childless_creative)
    perform_enqueued_jobs do
      Collavre::CreativeShare.create!(creative: creative, user: users(:two), permission: :read)
    end
    sign_in_as(users(:two), password: "password")

    get creatives_path(id: creative.id)

    assert_response :success
    assert_includes response.body, html_t("collavre.creatives.index.empty_state_heading_sub")
    assert_includes response.body, html_t("collavre.creatives.index.empty_state_readonly_message")
    assert_includes response.body, html_t("collavre.creatives.index.request_permission")
    assert_includes response.body, request_permission_creative_path(creative)
    refute_includes response.body, html_t("collavre.creatives.index.empty_state_add_sub_creative")
    refute_match(/add-creative-btn--cta/, response.body)
  end

  test "search-no-results branch is unaffected by the empty-state change" do
    sign_in_as(users(:one), password: "password")

    get creatives_path(search: "no-such-creative-zzz")

    assert_response :success
    assert_includes response.body, html_t("collavre.creatives.index.no_search_results")
    refute_includes response.body, html_t("collavre.creatives.index.empty_state_heading_root")
    refute_includes response.body, html_t("collavre.creatives.index.empty_state_concept_title")
  end

  test "requesting an unreadable or nonexistent id still renders the generic sub-creatives text without crashing" do
    sign_in_as(users(:one), password: "password")

    get creatives_path(id: 0)

    assert_response :success
    assert_includes response.body, html_t("collavre.creatives.index.empty_state_heading_sub")
    refute_includes response.body, html_t("collavre.creatives.index.empty_state_readonly_message")
    refute_includes response.body, html_t("collavre.creatives.index.request_permission")
  end

  test "unauthenticated visitor at root sees sign up / log in CTAs" do
    sign_out

    get creatives_path

    assert_response :success
    refute_match(/class="[^"]*\bnew-root-creative-btn\b/, response.body)
    refute_includes response.body, html_t("collavre.creatives.index.empty_state_add_creative")
    refute_includes response.body, html_t("collavre.creatives.index.empty_state_readonly_message")
    assert_includes response.body, html_t("collavre.creatives.index.empty_state_loggedout_message")
    assert_includes response.body, html_t("collavre.users.new.sign_up")
    assert_includes response.body, html_t("app.sign_in")
    assert_includes response.body, new_user_path
    assert_includes response.body, new_session_path
  end

  test "unauthenticated visitor on a publicly-shared childless creative sees sign up / log in CTAs" do
    creative = creatives(:childless_creative)
    perform_enqueued_jobs do
      Collavre::CreativeShare.create!(creative: creative, user: nil, permission: :read)
    end
    sign_out

    get creatives_path(id: creative.id)

    assert_response :success
    assert_includes response.body, html_t("collavre.creatives.index.empty_state_heading_sub")
    refute_includes response.body, html_t("collavre.creatives.index.empty_state_readonly_message")
    refute_includes response.body, html_t("collavre.creatives.index.empty_state_add_sub_creative")
    refute_match(/add-creative-btn--cta/, response.body)
    assert_includes response.body, html_t("collavre.creatives.index.empty_state_loggedout_message")
    assert_includes response.body, html_t("collavre.users.new.sign_up")
    assert_includes response.body, html_t("app.sign_in")
    assert_includes response.body, new_user_path
    assert_includes response.body, new_session_path
  end
end
