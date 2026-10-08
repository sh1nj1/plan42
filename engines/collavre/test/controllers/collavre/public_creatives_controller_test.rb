require "test_helper"

module Collavre
  class PublicCreativesControllerTest < ActionDispatch::IntegrationTest
    setup do
      SystemSetting.where(key: "creatives_login_required").destroy_all
      @owner = users(:one)
      @creative = Creative.create!(user: @owner, description: "<p>Public Plan</p>")
    end

    def publish(creative = @creative)
      perform_enqueued_jobs { CreativeShare.create!(creative: creative, user: nil, permission: :read) }
      creative.ensure_public_id!
    end

    test "renders a publicly shared creative signed out" do
      public_id = publish

      get public_creative_path(public_id: public_id, slug: "public-plan")

      assert_response :success
      assert_select "h1", "Public Plan"
      assert_select "title", /Public Plan/
      assert_select "a", text: I18n.t("collavre.public_creatives.show.open_in_app"), count: 0
    end

    test "offers the app view to a signed-in reader" do
      public_id = publish
      sign_in_as(users(:two), password: "password")

      get public_creative_path(public_id: public_id, slug: "public-plan")

      assert_response :success
      assert_select "a[href=?]", creatives_path(id: @creative.id), text: I18n.t("collavre.public_creatives.show.open_in_app")
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
      assert_select "h1", "!!!"
    end

    test "an untitled creative falls back to the untitled label" do
      @creative.update_column(:description, "")
      public_id = publish

      get public_creative_path(public_id: public_id)

      assert_response :success
      assert_select "h1", I18n.t("collavre.public_creatives.show.untitled")
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

    test "requires sign-in when creatives require login" do
      public_id = publish
      SystemSetting.create!(key: "creatives_login_required", value: "true")

      get public_creative_path(public_id: public_id, slug: "public-plan")

      assert_redirected_to new_session_path
    end
  end
end
