require "test_helper"

class CreativeDeleteMenuTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @user.update!(creative_workspace_enabled: true)
    sign_in_as(@user, password: "password")
    @parent = Creative.create!(user: @user, description: "Delete menu parent")
    @creative = Creative.create!(user: @user, parent: @parent, description: "Delete menu target")
    @child = Creative.create!(user: @user, parent: @creative, description: "Preserved child")
  end

  test "menu targets the current creative with localized confirmation in full and frame views" do
    %w[en ko].each do |locale|
      @user.update!(locale: locale)
      [ {}, { "Turbo-Frame" => "creative-workspace-content" } ].each do |headers|
        get creatives_path(id: @creative.id), headers: headers

        assert_response :success
        assert_select "#creative-overflow-menu form[action=?][data-turbo-frame='_top']", creative_path(@creative) do
          assert_select "[name='_method'][value='delete']"
          assert_select "#delete-current-creative-btn", text: I18n.t("collavre.creatives.index.delete", locale: locale)
        end
        assert_select "#creative-overflow-menu form[data-turbo-confirm=?]",
          I18n.t("collavre.creatives.index.are_you_sure_delete_only_this", locale: locale)
      end
    end
  end

  test "menu is hidden at root and for missing or inaccessible creatives" do
    private_creative = Creative.create!(user: users(:two), description: "Private")
    [ nil, private_creative.id, Creative.maximum(:id) + 1000 ].each do |id|
      get creatives_path(id: id)
      assert_response :success
      assert_select "#delete-current-creative-btn", count: 0
    end
  end

  test "non admin shares cannot see the menu or delete the creative" do
    %w[read feedback write].each do |permission|
      shared = Creative.create!(user: users(:two), description: "Shared")
      CreativeShare.create!(creative: shared, user: @user, permission: permission)
      get creatives_path(id: shared.id)
      assert_response :success
      assert_select "#delete-current-creative-btn", count: 0
      assert_no_difference "Creative.count" do
        delete creative_path(shared)
      end
      assert_redirected_to creative_path(shared)
    end
  end

  test "HTML deletion preserves children and redirects to the parent" do
    delete creative_path(@creative), headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }

    assert_response :see_other
    assert_redirected_to creatives_path(id: @parent.id)
    assert_not Creative.exists?(@creative.id)
    assert_equal @parent, @child.reload.parent
  end

  test "root deletion redirects to the root list" do
    delete creative_path(@parent)

    assert_response :see_other
    assert_redirected_to creatives_path
    assert_nil @creative.reload.parent_id
  end

  test "JSON deletion retains the no content response" do
    delete creative_path(@creative), headers: { "Accept" => "application/json" }

    assert_response :no_content
    assert_nil response.headers["Location"]
    assert_not Creative.exists?(@creative.id)
    assert_equal @parent, @child.reload.parent
  end

  test "deleting a linked creative leaves its origin intact" do
    link = Creative.create!(user: @user, parent: @parent, origin: @creative)
    delete creative_path(link)

    assert_redirected_to creatives_path(id: @parent.id)
    assert_not Creative.exists?(link.id)
    assert Creative.exists?(@creative.id)
  end
end
