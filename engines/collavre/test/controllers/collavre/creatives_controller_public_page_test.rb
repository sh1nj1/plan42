require "test_helper"

module Collavre
  class CreativesControllerPublicPageTest < ActionDispatch::IntegrationTest
    setup do
      SystemSetting.where(key: "creatives_login_required").destroy_all
      @owner = users(:one)
      @creative = Creative.create!(user: @owner, description: "<p>Public Plan</p>")
    end

    def publish(creative = @creative)
      perform_enqueued_jobs { CreativeShare.create!(creative: creative, user: nil, permission: :read) }
      creative.ensure_public_id!
    end

    test "renders the client-rendered creative view with server-rendered metadata" do
      public_id = publish
      Creative.create!(user: @owner, parent: @creative, description: "<p>First step</p><p>Details</p>")
      canonical = public_creative_url(public_id: public_id, slug: "public-plan")

      get public_creative_path(public_id: public_id, slug: "public-plan")

      assert_response :success
      assert_select "title", "Public Plan — #{I18n.t('app.name')}"
      assert_select "meta[name=description][content=?]", "First step Details"
      assert_select "link[rel=canonical][href=?]", canonical
      assert_select "meta[property='og:title'][content=?]", "Public Plan"
      assert_select "meta[property='og:description'][content=?]", "First step Details"
      assert_select "meta[property='og:url'][content=?]", canonical
      assert_select "meta[property='og:type'][content=article]"
      assert_select "meta[name='twitter:card'][content=summary]"
      assert_select "meta[name=robots]", count: 0
      assert_select "creative-tree-row[is-title][creative-id=?]", @creative.id.to_s
      assert_select "#creatives[data-creatives--tree-url-value*=?]", "id=#{@creative.id}"
    end

    test "the breadcrumb omits private ancestors of a nested public creative" do
      parent = Creative.create!(user: @owner, description: "<p>Private Parent Secret</p>")
      @creative.update!(parent: parent)
      public_id = publish

      get public_creative_path(public_id: public_id, slug: "public-plan")

      assert_response :success
      assert_select ".creative-breadcrumb-current", "Public Plan"
      assert_select ".creative-breadcrumb a[data-creative-id=?]", parent.id.to_s, count: 0
      assert_no_match "Private Parent Secret", response.body
    end

    test "the breadcrumb keeps ancestors the viewer can read" do
      parent = Creative.create!(user: @owner, description: "<p>Owner Parent</p>")
      @creative.update!(parent: parent)
      sign_in_as(@owner, password: "password")

      get creatives_path(id: @creative.id, view: "list")

      assert_response :success
      assert_select ".creative-breadcrumb a[data-creative-id=?]", parent.id.to_s, text: "Owner Parent"
    end

    test "the app view of a creative is not indexable" do
      publish

      get creatives_path(id: @creative.id, view: "list")

      assert_response :success
      assert_select "meta[name=robots][content=noindex]"
      assert_select "link[rel=canonical]", count: 0
    end

    test "sends a signed-in reader to the app view" do
      public_id = publish
      sign_in_as(users(:two), password: "password")

      get public_creative_path(public_id: public_id, slug: "public-plan")

      assert_redirected_to creatives_path(id: @creative.id)
    end

    test "redirects a missing or stale slug to the canonical address" do
      public_id = publish

      get public_creative_path(public_id: public_id)
      assert_redirected_to public_creative_path(public_id: public_id, slug: "public-plan")
      assert_response :moved_permanently

      get public_creative_path(public_id: public_id, slug: "old-title")
      assert_redirected_to public_creative_path(public_id: public_id, slug: "public-plan")
    end

    test "a title with no slug characters is served without a slug" do
      @creative.update!(description: "<p>!!!</p>")
      public_id = publish

      get public_creative_path(public_id: public_id)

      assert_response :success
      assert_select "meta[property='og:title'][content=?]", "!!!"
    end

    test "an untitled creative falls back to the untitled label" do
      @creative.update_column(:description, "")
      public_id = publish

      get public_creative_path(public_id: public_id)

      assert_response :success
      untitled = I18n.t("collavre.public_creatives.show.untitled")
      assert_select "meta[property='og:title'][content=?]", untitled
      assert_select "meta[name=description][content=?]", untitled
    end

    test "a creative that is not public is a 404 even with a public id" do
      public_id = @creative.ensure_public_id!

      get public_creative_path(public_id: public_id, slug: "public-plan")

      assert_response :not_found
    end

    test "revoking the public share keeps the id but hides the page" do
      public_id = publish
      perform_enqueued_jobs { CreativeShare.find_by!(creative: @creative, user_id: nil).destroy! }

      get public_creative_path(public_id: public_id, slug: "public-plan")

      assert_response :not_found
      assert_equal public_id, @creative.reload.public_id
    end

    test "an unknown public id is a 404" do
      get public_creative_path(public_id: "ZZZZZZZZZZ")

      assert_response :not_found
    end

    test "a linked creative has no public page of its own" do
      publish
      link = Creative.create!(user: users(:two), origin: @creative)
      Creative.where(id: link.id).update_all(public_id: "LLLLLLLLLL")

      get public_creative_path(public_id: "LLLLLLLLLL")

      assert_response :not_found
    end

    test "a signed-in reader denied the creative gets a 404" do
      public_id = publish
      perform_enqueued_jobs { CreativeShare.create!(creative: @creative, user: users(:two), permission: :no_access) }
      sign_in_as(users(:two), password: "password")

      get public_creative_path(public_id: public_id, slug: "public-plan")

      assert_response :not_found
    end

    test "requires sign-in when creatives require login" do
      public_id = publish
      SystemSetting.create!(key: "creatives_login_required", value: "true")

      get public_creative_path(public_id: public_id, slug: "public-plan")

      assert_redirected_to new_session_path
    end
  end
end
