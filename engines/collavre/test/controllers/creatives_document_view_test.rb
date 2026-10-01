require "test_helper"

class CreativesDocumentViewTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user, password: "password")
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
    en: [ "Document view", "Open" ],
    ko: [ "문서 뷰", "열기" ]
  }.each do |locale, (toggle, open)|
    test "document view labels are localized in #{locale}" do
      @user.update!(locale: locale)

      get creatives_path

      assert_select "#document-view-btn[title=?][aria-label=?]", toggle, toggle
      assert_select "#creatives[data-document-open-label=?]", open
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
