require "test_helper"

module Collavre
  # The landing demo videos are full absolute URLs stored per-locale in
  # config/locales/landing.*.yml. The page embeds them directly — no auth, no
  # Creative lookup — so these tests assert the configured URL for the active
  # locale reaches the rendered page and the other locale's URL does not.
  class LandingControllerTest < ActionDispatch::IntegrationTest
    def demo_video(locale)
      I18n.t("collavre.landing.demo.video", locale: locale)
    end

    def footer_copy(locale)
      I18n.t(
        "collavre.landing.footer.copyright",
        locale: locale,
        year: Date.today.year,
        app_name: I18n.t("app.name", locale: locale)
      )
    end

    test "embeds the English demo video URL from the locale config" do
      get "/landing"
      assert_response :success

      assert_includes response.body, demo_video(:en)
      assert_not_includes response.body, demo_video(:ko)
      assert_includes response.body, footer_copy(:en)
    end

    test "embeds the Korean demo video URL when locale is ko" do
      get "/landing", params: { locale: "ko" }
      assert_response :success

      assert_includes response.body, demo_video(:ko)
      assert_not_includes response.body, demo_video(:en)
      assert_includes response.body, footer_copy(:ko)
    end

    test "the configured demo URL is a full absolute URL, not a host-relative path" do
      get "/landing"
      assert_response :success

      assert_match %r{\Ahttps://}, demo_video(:en),
                   "demo URL must be absolute so it resolves from any environment (preview included)"
      assert_includes response.body, "https://"
    end
  end
end
