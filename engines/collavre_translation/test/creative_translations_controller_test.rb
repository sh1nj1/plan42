require_relative "test_helper"

module CollavreTranslation
  class CreativeTranslationsControllerTest < ActionDispatch::IntegrationTest
    include TranslationQueueTestHelper

    setup do
      use_translation_test_queue
      CollavreTranslation.model = "test-model"
      @user = users(:one)
      @user.update!(locale: "ko")
      sign_in_as @user, password: "password"
      @creative = Collavre::Creative.create!(user: @user, description: "English title and body for creative translation.")
      @url = "/translation/creatives/#{@creative.id}/translation"
    end

    teardown do
      restore_translation_queue
      CollavreTranslation.model = nil
    end

    test "GET is read only and POST uses reader locale and shares cache" do
      assert_no_difference "Translation.count" do
        get @url
      end
      assert_equal "missing", response.parsed_body["status"]
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_enqueued_jobs 1, only: TranslateJob do
        2.times { post @url; assert_response :success }
      end
      record = Translation.for_creative(@creative, "ko")
      record.update!(status: "completed", content: "[]")
      get @url
      assert_equal "[]", response.parsed_body["content"]
      @creative.update!(description: "Changed original")
      get @url
      assert_equal "missing", response.parsed_body["status"]
    end

    test "embed=0 returns the stored source so tree labels keep YouTube link text" do
      link = '<a href="https://youtu.be/dQw4w9WgXcQ">my video</a>'
      @creative.update!(description: "<p>Watch #{link}</p>")
      get @url
      assert_includes response.parsed_body["original_html"], "youtube.com/embed/dQw4w9WgXcQ"
      assert_not_includes response.parsed_body["original_html"], "my video"
      digest = response.parsed_body["source_digest"]
      get @url, params: { embed: "0" }
      assert_equal "<p>Watch #{link}</p>", response.parsed_body["original_html"]
      assert_equal digest, response.parsed_body["source_digest"]
      assert_equal Collavre::HtmlText.label(@creative.effective_description),
        Collavre::HtmlText.label(response.parsed_body["original_html"])
    end

    test "anonymous readers cannot access translations" do
      sign_out
      get @url, headers: { "X-Requested-With" => "XMLHttpRequest" }
      assert_response :unauthorized
    end

    test "unauthorized readers cannot access translations" do
      sign_out
      sign_in_as users(:three), password: "password"
      assert_no_enqueued_jobs only: TranslateJob do
        get @url
        assert_response :forbidden
        post @url
        assert_response :forbidden
      end
    end

    test "disabled model and user policy block both cache reads and requests" do
      [ false, true ].each do |disabled_model|
        CollavreTranslation.model = disabled_model ? "" : "test-model"
        CreativeTranslationPolicy.stub :enabled?, false do
          assert_no_enqueued_jobs only: TranslateJob do
            get @url
            assert_response(disabled_model ? :service_unavailable : :forbidden)
            post @url
            assert_response(disabled_model ? :service_unavailable : :forbidden)
          end
        end
      end
    end

    test "reader OFF blocks existing cache and requests after permission checks" do
      Translation.request!(@creative, "ko").update!(status: "completed", content: "[]")
      CreativeTranslationPolicy.stub :enabled?, ->(user) { assert_equal @user, user; false } do
        Translation.stub :for_creative, ->(*) { flunk "must not read cache" } do
          Translation.stub :request!, ->(*) { flunk "must not request job" } do
            get @url
            assert_response :forbidden
            post @url
            assert_response :forbidden
          end
        end
      end
      sign_out
      sign_in_as users(:three), password: "password"
      CreativeTranslationPolicy.stub :enabled?, ->(*) { flunk "permission must be checked first" } do
        get @url
        assert_response :forbidden
        post @url
        assert_response :forbidden
      end
    end

    test "persisted reader preference gates creative cache requests and controller independently" do
      Translation.request!(@creative, "ko").update!(status: "completed", content: "[]")
      Collavre::CreativeSharesCache.create!(creative: @creative, user: users(:two), permission: :read)
      @user.update!(auto_translation_enabled: false)
      assert_no_enqueued_jobs only: TranslateJob do
        get @url
        assert_response :forbidden
        post @url
        assert_response :forbidden
      end
      get "/creatives", params: { id: @creative.id }
      assert_response :success
      assert_select '[data-controller="creative-translations"]', count: 0

      delete "/session"
      users(:two).update!(locale: "ko", auto_translation_enabled: true)
      sign_in_as users(:two), password: "password"
      get @url
      assert_response :success
      assert_equal "[]", response.parsed_body["content"]
      reader_creative = Collavre::Creative.create!(user: users(:two), description: "Reader original")
      get "/creatives", params: { id: reader_creative.id }
      assert_response :success
      assert_select '[data-controller="creative-translations"]', count: 1
      refute @user.reload.auto_translation_enabled?
    end

    test "unsupported locale rejects requests and blank locale uses default" do
      @user.update_column(:locale, "fr")
      post @url
      assert_response :unprocessable_entity
      @user.update_column(:locale, nil)
      post @url
      assert_response :success
    end

    test "creative page mounts engine extension only when user gate is enabled" do
      get collavre.creatives_path(id: @creative.id)
      assert_response :success
      assert_select '[data-controller="creative-translations"]', count: 1
      CreativeTranslationPolicy.stub :enabled?, false do
        get collavre.creatives_path(id: @creative.id)
        assert_select '[data-controller="creative-translations"]', count: 0
      end
    end
  end
end
