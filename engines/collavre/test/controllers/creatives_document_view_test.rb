require "test_helper"

class CreativesDocumentViewTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user, password: "password")
  end

  test "filtered title and body reflect a tagged leaf progress change" do
    parent = Creative.create!(description: "Filtered parent", user: @user)
    leaf = Creative.create!(description: "Tagged leaf", user: @user, parent: parent, progress: 0)
    Creative.create!(description: "Other leaf", user: @user, parent: parent, progress: 0)
    label = Label.create!(creative: leaf, owner: @user)
    Tag.create!(creative_id: leaf.id, label: label)
    path = creatives_path(id: parent.id, tags: [ label.id.to_s ], format: :json)
    get path
    assert_equal 0, response.parsed_body.dig("title_progress", "display_progress")
    patch creative_path(leaf), params: { creative: { progress: 1 } }, as: :json
    assert_response :success
    get path
    assert_response :success
    assert_equal 1, response.parsed_body.dig("title_progress", "display_progress")
    assert_equal 0.5, parent.reload.progress
  end

  test "empty combined filters preserve zero title progress instead of tag-only progress" do
    parent = Creative.create!(description: "Filtered parent", user: @user)
    leaf = Creative.create!(description: "Tagged completed leaf", user: @user, parent: parent, progress: 1)
    label = Label.create!(creative: leaf, owner: @user)
    Tag.create!(creative_id: leaf.id, label: label)
    get creatives_path(id: parent.id, tags: [ label.id.to_s ], search: "nonexistent-filter-match", format: :json)
    assert_response :success
    assert_empty response.parsed_body.fetch("creatives")
    title = response.parsed_body.fetch("title_progress")
    assert_equal parent.id, title["id"]
    assert_equal 0, title["display_progress"]
    assert_includes title["progress_html"], 'creative-progress-incomplete">0%</span>'
    get creatives_path(id: parent.id, tags: [ label.id.to_s ], search: "Tagged", format: :json)
    assert_response :success
    assert_equal 1, response.parsed_body.dig("title_progress", "display_progress")
  end

  test "initial HTML title uses combined filter progress before the JSON tree loads" do
    parent = Creative.create!(description: "Filtered parent", user: @user)
    leaf = Creative.create!(description: "Tagged completed leaf", user: @user, parent: parent, progress: 1)
    label = Label.create!(creative: leaf, owner: @user)
    Tag.create!(creative_id: leaf.id, label: label)
    get creatives_path(id: parent.id, tags: [ label.id.to_s ], search: "nonexistent-filter-match", view: "document")
    assert_response :success
    assert_select "creative-tree-row[is-title][data-display-progress='0']"
    assert_select "creative-tree-row[is-title] template[data-part='progress'] .creative-progress-incomplete", text: "0%"
    get creatives_path(id: parent.id, tags: [ label.id.to_s ], search: "Tagged", view: "document")
    assert_response :success
    assert_select "creative-tree-row[is-title][data-display-progress='1.0']"
  end

  test "filtered title refresh does not expose an unreadable parent" do
    creative = Creative.create!(description: "Private doc", user: users(:two))
    get creatives_path(id: creative.id, tags: [ "999999" ], format: :json)
    assert_response :success
    assert_nil response.parsed_body["title_progress"]
  end

  test "filtered JSON refetch includes current title progress" do
    creative = Creative.create!(description: "Complete doc", user: @user, progress: 1)
    get creatives_path(id: creative.id, tags: [ "999999" ], format: :json)
    assert_response :success
    title = response.parsed_body.fetch("title_progress")
    assert_equal creative.id, title["id"]
    assert_equal 0, title["display_progress"]
    assert_includes title["progress_html"], 'data-current-progress="0"'
    get creatives_path(id: creative.id, format: :json)
    assert_nil response.parsed_body["title_progress"]
  end

  test "tree view is the default and offers the document view toggle" do
    get creatives_path

    assert_response :success
    assert_select "[data-controller~='creatives--document-view'][data-creatives--document-view-active-value='false']"
    assert_select ".creative-document-view", count: 0
    assert_select "#document-view-btn[aria-pressed='false'][data-action='click->creatives--document-view#toggle']"
    assert_select "#creatives[data-creatives--document-view-target='tree']"
    assert_select "#creatives[data-view-mode]", count: 0
    assert_select "#creatives[data-dnd-disabled]", count: 0
  end

  test "view=document renders the document view up front" do
    get creatives_path(view: "document")

    assert_response :success
    assert_select ".creative-document-view[data-creatives--document-view-active-value='true']"
    assert_select "#document-view-btn[aria-pressed='true']"
    assert_select "#creatives[data-view-mode='document'][data-dnd-disabled]"
  end

  test "title background receives filtered progress separately from editor progress" do
    creative = Creative.create!(description: "Complete doc", user: @user, progress: 1)
    get creatives_path(id: creative.id, view: "document", tags: [ "999999" ])
    assert_response :success
    assert_select "creative-tree-row[is-title][data-progress-value='1.0'][data-display-progress='0']"

    get creatives_path(id: creative.id, view: "document")
    assert_select "creative-tree-row[is-title][data-display-progress]", count: 0
  end

  test "the remembered view follows the user into any creative" do
    creative = Creative.create!(description: "Parent doc", user: @user)
    child = Creative.create!(description: "Child doc", user: @user, parent: creative)
    cookies[:creative_view] = "document"

    [ creatives_path, creatives_path(id: creative.id), creatives_path(id: child.id) ].each do |path|
      get path

      assert_response :success
      assert_select ".creative-document-view #creatives[data-view-mode='document'][data-dnd-disabled]"
      assert_select "#document-view-btn[aria-pressed='true']"
    end
  end

  test "an explicit view wins over the remembered one" do
    cookies[:creative_view] = "document"

    get creatives_path(view: "tree")

    assert_response :success
    assert_select ".creative-document-view", count: 0
    assert_select "#document-view-btn[aria-pressed='false']"
  end

  test "an unknown view falls back to the tree" do
    get creatives_path(view: "kanban")

    assert_response :success
    assert_select ".creative-document-view", count: 0
    assert_select "#document-view-btn[aria-pressed='false']"
  end

  test "the view parameter is not forwarded to the tree data request" do
    get creatives_path(view: "document")

    tree_url = css_select("#creatives").first["data-creatives--tree-url-value"]
    assert_not_includes tree_url, "view="
  end

  {
    en: "Document view",
    ko: "문서 뷰"
  }.each do |locale, toggle|
    test "document view labels are localized in #{locale}" do
      @user.update!(locale: locale)

      get creatives_path

      assert_select "#document-view-btn[title=?][aria-label=?]", toggle, toggle
      hint = I18n.t("collavre.dnd.document_drag_handle_hint", locale: locale)
      assert_select "[data-drag-handle-hint=?]", hint
    end
  end

  test "a creative link keeps the document view through the index redirect" do
    creative = Creative.create!(description: "Linked doc", user: @user)

    get creative_path(creative, view: "document")

    assert_redirected_to creatives_path(id: creative.id, view: "document")
  end

  test "readers without write access still get the toggle" do
    owner = users(:two)
    creative = Creative.create!(description: "Shared doc", user: owner)
    CreativeShare.create!(creative: creative, user: @user, permission: :read)

    get creative_path(creative)
    follow_redirect! if response.redirect?

    assert_response :success
    assert_select ".creative-header-actions .add-creative-btn", count: 0
    assert_select ".creative-header-actions #document-view-btn"
  end
end
