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

    test "renders the public subtree as an outline signed out" do
      child = Creative.create!(user: @owner, parent: @creative, description: "<p>Goals</p>", sequence: 1)
      Creative.create!(user: @owner, parent: child, description: "<p>First</p><p>Second paragraph</p>", sequence: 1)
      hidden = Creative.create!(user: @owner, parent: @creative, description: "<p>Secret</p>", sequence: 2)
      public_id = publish
      perform_enqueued_jobs { CreativeShare.create!(creative: hidden, user: nil, permission: :no_access) }

      get public_creative_path(public_id: public_id, slug: "public-plan")

      assert_response :success
      assert_select "h2.public-creative-heading", "Goals"
      assert_select ".public-creative-body p", "Second paragraph"
      assert_not_includes response.body, "Secret"
      assert_select ".public-creative-truncated", count: 0
      assert_select ".public-creative-cta a[href=?]", new_user_path
    end

    test "a rich root description is rendered below the title" do
      @creative.update!(description: "<p>Overview</p><ul><li>Point one</li></ul>")
      public_id = publish

      get public_creative_path(public_id: public_id, slug: "overview")

      assert_response :success
      assert_select "h1", "Overview"
      assert_select ".public-creative-body li", "Point one"
      assert_select ".public-creative-body p", text: "Overview", count: 0
    end

    test "notes when the page shows only part of a large tree" do
      Creative.create!(user: @owner, parent: @creative, description: "Child", sequence: 1)
      public_id = publish
      limited = ->(creative, **options) { Creatives::PublicTreeBuilder.allocate.tap { |builder| builder.send(:initialize, creative, limit: 0) } }

      Creatives::PublicTreeBuilder.stub(:new, limited) do
        get public_creative_path(public_id: public_id, slug: "public-plan")
      end

      assert_select ".public-creative-truncated", I18n.t("collavre.public_creatives.show.truncated")
    end

    test "signed-in readers see the anonymous view without the sign-up prompt" do
      private_child = Creative.create!(user: @owner, parent: @creative, description: "Owner only", sequence: 1)
      public_id = publish
      perform_enqueued_jobs { CreativeShare.create!(creative: private_child, user: nil, permission: :no_access) }
      sign_in_as(@owner, password: "password")

      get public_creative_path(public_id: public_id, slug: "public-plan")

      assert_response :success
      assert_not_includes response.body, "Owner only"
      assert_select ".public-creative-cta", count: 0
    end

    test "login-gated public pages honor user-specific denies" do
      public_id = publish
      SystemSetting.create!(key: "creatives_login_required", value: "true")
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
