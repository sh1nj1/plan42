require "test_helper"

module Collavre
  # The guide pages double as landing content: they are readable signed out, and
  # their copy comes entirely from config/locales/features.*.yml keyed off the
  # feature card registry.
  class FeaturesControllerTest < ActionDispatch::IntegrationTest
    GUIDE_KEYS = %w[mention_agent slash_command chat_context automation_trigger topic_management add_user].freeze

    # Card titles and guide copy contain characters ERB escapes ("&", "'"), so
    # every body assertion compares against the escaped form.
    def escaped(key, **options)
      ERB::Util.html_escape(I18n.t(key, **options))
    end

    test "index lists every card that opts into the built-in guide" do
      get "/features"

      assert_response :success
      GUIDE_KEYS.each do |key|
        assert_includes @response.body, "/features/#{key}",
                        "expected the hub to link the #{key} guide"
        assert_includes @response.body, escaped("collavre.comments.empty_state.cards.#{key}.title")
      end
    end

    # The call to action carries a directional glyph. It belongs to the translated
    # string so a translator can reorder or drop it, rather than being concatenated
    # in the view where they cannot reach it.
    test "index renders the card call to action entirely from i18n" do
      get "/features"

      assert_response :success
      assert_includes @response.body, escaped("collavre.features.index.card_more")
      assert_includes I18n.t("collavre.features.index.card_more"), "→"
      assert_includes I18n.t("collavre.features.index.card_more", locale: :ko), "→"
    end

    test "index is readable without signing in" do
      get "/features"

      assert_response :success
      assert_includes @response.body, escaped("collavre.features.index.title")
    end

    test "show renders the guide copy for each registered feature" do
      GUIDE_KEYS.each do |key|
        get "/features/#{key}"

        assert_response :success, "expected /features/#{key} to render"
        assert_includes @response.body, escaped("collavre.features.pages.#{key}.title")
        assert_includes @response.body, escaped("collavre.features.pages.#{key}.tagline")
      end
    end

    test "show renders every section and tip from the locale file" do
      get "/features/slash_command"

      assert_response :success
      sections = I18n.t("collavre.features.pages.slash_command.sections")
      assert sections.any?, "fixture assumption: slash_command has sections"
      sections.each do |section|
        assert_includes @response.body, ERB::Util.html_escape(section[:heading])
        assert_includes @response.body, ERB::Util.html_escape(section[:body])
      end

      tips = I18n.t("collavre.features.pages.slash_command.tips")
      assert tips.any?, "fixture assumption: slash_command has tips"
      assert_includes @response.body, escaped("collavre.features.show.tips")
      tips.each { |tip| assert_includes @response.body, ERB::Util.html_escape(tip) }
    end

    test "agent and compress tips describe the routing and permission fallbacks in both locales" do
      {
        en: [ "primary agent", "routing rules", "comment permission", "policy primary agent" ],
        ko: [ "주 담당 에이전트", "라우팅 규칙", "댓글 권한", "정책의 주 담당 에이전트" ]
      }.each do |locale, phrases|
        copy = [
          *I18n.t("collavre.features.pages.mention_agent.tips", locale: locale),
          *I18n.t("collavre.features.pages.slash_command.tips", locale: locale),
          *I18n.t("collavre.features.pages.topic_management.tips", locale: locale)
        ].join(" ")

        phrases.each { |phrase| assert_includes copy, phrase }
      end
    end

    test "feature pages render the complete localized footer sentence" do
      { "/features" => :en, "/features/mention_agent" => :ko }.each do |path, locale|
        get path, params: { locale: locale }

        expected = I18n.t(
          "collavre.landing.footer.copyright",
          locale: locale,
          year: Date.today.year,
          app_name: I18n.t("app.name", locale: locale)
        )
        assert_response :success
        assert_includes @response.body, ERB::Util.html_escape(expected)
      end
    end

    test "show uses the page title and description for meta tags rather than the landing copy" do
      get "/features/mention_agent"

      assert_response :success
      assert_includes @response.body, "<title>#{escaped('app.name')} — #{escaped('collavre.features.pages.mention_agent.title')}</title>"
      assert_includes @response.body, escaped("collavre.features.pages.mention_agent.meta_description")
      assert_not_includes @response.body, escaped("collavre.landing.meta.description")
    end

    test "show serves Korean copy when the locale is ko" do
      get "/features/topic_management", params: { locale: "ko" }

      assert_response :success
      assert_includes @response.body, escaped("collavre.features.pages.topic_management.tagline", locale: :ko)
      assert_not_includes @response.body, escaped("collavre.features.pages.topic_management.tagline", locale: :en)
    end

    test "topic guide shows the required mention colon in both locales" do
      { en: '/topic "name" @agent:', ko: '/topic "이름" @에이전트:' }.each do |locale, command|
        get "/features/topic_management", params: { locale: locale }

        assert_response :success
        assert_includes @response.body, ERB::Util.html_escape(command)
      end
    end

    test "show 404s for a key that is not registered" do
      get "/features/not_a_feature"

      assert_response :not_found
    end

    # A vendor engine documenting its card elsewhere gets no page here, so the
    # route must not render an empty shell for it.
    test "show 404s for a card that points at its own guide url" do
      Collavre::FeatureCardRegistry.register(:vendor_card, {
        title_key: "collavre.comments.empty_state.cards.add_user.title",
        description_key: "collavre.comments.empty_state.cards.add_user.description",
        guide: true,
        guide_url: "https://example.com/docs/vendor"
      })

      get "/features/vendor_card"

      assert_response :not_found
    ensure
      Collavre::FeatureCardRegistry.unregister(:vendor_card)
    end

    test "index omits a card that points at its own guide url" do
      Collavre::FeatureCardRegistry.register(:vendor_card, {
        title_key: "collavre.comments.empty_state.cards.add_user.title",
        description_key: "collavre.comments.empty_state.cards.add_user.description",
        guide: true,
        guide_url: "https://example.com/docs/vendor"
      })

      get "/features"

      assert_response :success
      assert_not_includes @response.body, "/features/vendor_card"
    ensure
      Collavre::FeatureCardRegistry.unregister(:vendor_card)
    end

    # A translator can ship a page before its sections exist. I18n returns a
    # String for a missing key where the view walks an Array, so the controller
    # normalizes rather than 500ing.
    test "show renders without sections or tips when that copy is missing" do
      Collavre::FeatureCardRegistry.register(:bare_card, {
        title_key: "collavre.comments.empty_state.cards.add_user.title",
        description_key: "collavre.comments.empty_state.cards.add_user.description",
        guide: true
      })

      get "/features/bare_card"

      assert_response :success
      assert_includes @response.body, escaped("collavre.comments.empty_state.cards.add_user.title")
      assert_not_includes @response.body, escaped("collavre.features.show.tips")
    ensure
      Collavre::FeatureCardRegistry.unregister(:bare_card)
    end

    test "landing links to the features hub" do
      get "/landing"

      assert_response :success
      assert_includes @response.body, "/features"
      assert_includes @response.body, escaped("collavre.landing.features.explore")
    end
  end
end
