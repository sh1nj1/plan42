require "test_helper"

module Collavre
  # The guide pages double as landing content: they are readable signed out, and
  # their copy comes entirely from config/locales/features.*.yml keyed off the
  # feature card registry.
  class FeaturesControllerTest < ActionDispatch::IntegrationTest
    GUIDE_KEYS = %w[
      mention_agent slash_command chat_context automation_trigger topic_management add_user
      inbox_notifications inbox_reply inbox_source
    ].freeze

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

    test "index renders a localized home button and preserves the mount prefix" do
      request_env = { "SCRIPT_NAME" => "/collavre" }

      %i[en ko].each do |locale|
        get "/features", params: { locale: locale }, env: request_env

        assert_response :success
        assert_select "a.landing-btn.landing-btn-ghost[href=?]", "/collavre/landing?locale=#{locale}",
                      text: I18n.t("collavre.features.nav.back_home", locale: locale), count: 1
      end
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

    test "slash command guide distinguishes local calendar events and registered MCP tools in both locales" do
      {
        en: [ "local calendar event", "Google Calendar is connected", "MCP tools registered in your workspace" ],
        ko: [ "로컬 캘린더 일정", "Google Calendar가 연결", "워크스페이스에 등록된 MCP 도구" ]
      }.each do |locale, phrases|
        get "/features/slash_command", params: { locale: locale }

        assert_response :success
        phrases.each { |phrase| assert_includes @response.body, ERB::Util.html_escape(phrase) }
        assert_not_includes @response.body, "Notion"
        assert_not_includes @response.body, "Slack"
      end
    end

    test "slash command guide describes the creative picker separately in both locales" do
      {
        en: [ "/creative works differently", "Creative picker", "inserts your selection as a link in the draft", "send the message yourself" ],
        ko: [ "/creative는 다르게 동작", "Creative 선택 창", "링크를 초안에 삽입", "사용자가 직접 메시지를 전송" ]
      }.each do |locale, phrases|
        get "/features/slash_command", params: { locale: locale }

        assert_response :success
        phrases.each { |phrase| assert_includes @response.body, ERB::Util.html_escape(phrase) }
      end
    end

    test "slash command guide describes form command draft stashing in both locales" do
      {
        en: [ "form-backed command", "stashes the draft", "submits the command alone", "restores the draft" ],
        ko: [ "인자 폼이 있는 명령", "초안을 잠시 보관", "명령만 따로 전송", "초안을 복원" ]
      }.each do |locale, phrases|
        get "/features/slash_command", params: { locale: locale }

        assert_response :success
        phrases.each { |phrase| assert_includes @response.body, ERB::Util.html_escape(phrase) }
      end
    end

    test "slash command guide describes existing topic routing and its write permission in both locales" do
      {
        en: [ "If that name already exists", "assigns or replaces its primary agent", "releases any existing primary agent", "write permission" ],
        ko: [ "같은 이름이 이미 있으면", "주 담당 에이전트를 지정하거나 교체", "지정되어 있던 주 담당 에이전트를 해제", "쓰기 권한" ]
      }.each do |locale, phrases|
        get "/features/slash_command", params: { locale: locale }

        assert_response :success
        phrases.each { |phrase| assert_includes @response.body, ERB::Util.html_escape(phrase) }
      end
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

    test "mention guide renders discoverability and creative permission distinctions in both locales" do
      {
        en: [ "whitespace or one of : . , ;", "very start of a message only", "only for AI routing", "canonical @name: form", "does not create a teammate notification", "Creative owner", "comment permission", "globally searchable", "read-only collaborator", "cannot read or reply" ],
        ko: [ "공백 뒤, 또는 : . , ; 중 하나 뒤", "메시지 맨 앞에서는", "AI 라우팅에만 사용", "@이름: 표준 형식", "팀원 멘션 알림은 만들지 않습니다", "Creative 소유자", "댓글 이상의 권한", "전역 검색", "읽기 전용 참여자", "읽거나 답하지 못합니다" ]
      }.each do |locale, phrases|
        get "/features/mention_agent", params: { locale: locale }

        assert_response :success
        phrases.each { |phrase| assert_includes @response.body, ERB::Util.html_escape(phrase) }
      end
    end

    test "context guide renders the configured child-depth limit in both locales" do
      {
        en: [ "same configured depth", "six descendant levels by default", "zero includes only the referenced Creative" ],
        ko: [ "같은 설정 깊이", "기본값은 하위 6단계", "0이면 참조한 Creative만 포함" ]
      }.each do |locale, phrases|
        get "/features/chat_context", params: { locale: locale }

        assert_response :success
        phrases.each { |phrase| assert_includes @response.body, ERB::Util.html_escape(phrase) }
      end
    end

    test "slash command guide applies the configured child-depth limit to creative links in both locales" do
      {
        en: "agent's configured child-depth limit",
        ko: "에이전트에 설정된 하위 깊이 한도"
      }.each do |locale, phrase|
        get "/features/slash_command", params: { locale: locale }

        assert_response :success
        assert_includes @response.body, ERB::Util.html_escape(phrase)
      end
    end

    test "trigger and sharing guides render their input and mention permission limits in both locales" do
      {
        en: [ "first 24 visible characters", "not the full description", "comment permission or higher", "read-only collaborator" ],
        ko: [ "처음 24자", "전체 설명이 아니라", "댓글 이상의 권한", "읽기 전용 참여자" ]
      }.each do |locale, phrases|
        responses = %w[automation_trigger add_user].map do |key|
          get "/features/#{key}", params: { locale: locale }

          assert_response :success
          @response.body
        end
        rendered_copy = responses.join(" ")

        phrases.each { |phrase| assert_includes rendered_copy, ERB::Util.html_escape(phrase) }
      end
    end

    test "trigger guide describes DONE verification as best effort in both locales" do
      {
        en: [ "best-effort basis", "no verifier is available", "returns no response", "verification request fails", "accepts DONE" ],
        ko: [ "가능한 범위에서 검증", "검증 에이전트가 없거나", "검증 응답이 비어 있거나", "검증 요청이 실패하면", "DONE을 수락" ]
      }.each do |locale, phrases|
        get "/features/automation_trigger", params: { locale: locale }

        assert_response :success
        phrases.each { |phrase| assert_includes @response.body, ERB::Util.html_escape(phrase) }
      end
    end

    test "inbox guides explain the System topic behavior in both locales" do
      {
        en: [ "notification-only topic", "most recent preceding System notification", "Creative link" ],
        ko: [ "알림 전용 토픽", "가장 최근 System 알림", "Creative 링크" ]
      }.each do |locale, phrases|
        responses = %w[inbox_notifications inbox_reply inbox_source].map do |key|
          get "/features/#{key}", params: { locale: locale }

          assert_response :success
          @response.body
        end
        rendered_copy = responses.join(" ")

        phrases.each { |phrase| assert_includes rendered_copy, ERB::Util.html_escape(phrase) }
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

    test "show renders the breadcrumb separator from i18n in both locales" do
      %i[en ko].each do |locale|
        get "/features/mention_agent", params: { locale: locale }

        assert_response :success
        assert_select ".feature-guide-breadcrumb span[aria-hidden='true']",
                      text: I18n.t("collavre.features.nav.separator", locale: locale),
                      count: 1
      end
    end

    test "guide navigation preserves the selected locale" do
      get "/features", params: { locale: "ko" }

      assert_response :success
      assert_select "a[href=?]", "/landing?locale=ko"
      assert_select "a[href=?]", "/users/new?locale=ko"
      GUIDE_KEYS.each do |key|
        assert_select "a[href=?]", "/features/#{key}?locale=ko"
      end

      get "/features/mention_agent", params: { locale: "ko" }

      assert_response :success
      assert_select "a[href=?]", "/landing?locale=ko"
      assert_select "a[href=?]", "/features?locale=ko", count: 2
    end

    test "guide navigation preserves the engine mount prefix" do
      request_env = { "SCRIPT_NAME" => "/collavre" }

      get "/features", params: { locale: "ko" }, env: request_env

      assert_response :success
      assert_select "a[href=?]", "/collavre/landing?locale=ko"
      assert_select "a[href=?]", "/collavre/users/new?locale=ko"
      GUIDE_KEYS.each do |key|
        assert_select "a[href=?]", "/collavre/features/#{key}?locale=ko"
      end

      get "/features/mention_agent", params: { locale: "ko" }, env: request_env

      assert_response :success
      assert_select "a[href=?]", "/collavre/landing?locale=ko"
      assert_select "a[href=?]", "/collavre/features?locale=ko", count: 2

      get "/landing", params: { locale: "ko" }, env: request_env

      assert_response :success
      assert_select "a[href=?]", "/collavre/features?locale=ko",
                    text: I18n.t("collavre.landing.features.explore", locale: :ko)
    end

    test "topic guide shows the required mention colon in both locales" do
      { en: '/topic "name" @agent:', ko: '/topic "이름" @에이전트:' }.each do |locale, command|
        get "/features/topic_management", params: { locale: locale }

        assert_response :success
        assert_includes @response.body, ERB::Util.html_escape(command)
      end
    end

    test "topic guide distinguishes the ambient primary agent from an explicit mention in both locales" do
      {
        en: [ "sole ambient responder", "Explicitly mentioning another agent invites that agent instead" ],
        ko: [ "멘션 없는 메시지에 단독으로 답하는", "명시적으로 멘션하면 그 에이전트가 대신 답합니다" ]
      }.each do |locale, phrases|
        get "/features/topic_management", params: { locale: locale }

        assert_response :success
        phrases.each { |phrase| assert_includes @response.body, ERB::Util.html_escape(phrase) }
      end
    end

    test "topic guide describes existing names and the primary-agent write gate in both locales" do
      {
        en: [ "If that name already exists", "existing topic's primary agent", "without a mention releases", "write permission" ],
        ko: [ "같은 이름의 토픽이 이미 있으면", "기존 토픽의 주 담당 에이전트", "멘션 없이", "쓰기 권한" ]
      }.each do |locale, phrases|
        get "/features/topic_management", params: { locale: locale }

        assert_response :success
        phrases.each { |phrase| assert_includes @response.body, ERB::Util.html_escape(phrase) }
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

    test "landing links to the features hub and preserves the selected locale" do
      get "/landing", params: { locale: "ko" }

      assert_response :success
      assert_select "a[href=?]", "/features?locale=ko",
                    text: I18n.t("collavre.landing.features.explore", locale: :ko)
    end
  end
end
