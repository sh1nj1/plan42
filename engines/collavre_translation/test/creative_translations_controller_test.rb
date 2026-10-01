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

    test "unsupported locale rejects requests and blank locale uses default" do
      @user.update_column(:locale, "fr")
      post @url
      assert_response :unprocessable_entity
      @user.update_column(:locale, nil)
      post @url
      assert_response :success
    end

    test "creative page mounts engine extension only when user gate is enabled" do
      get creatives_path(id: @creative.id)
      assert_response :success
      assert_select '[data-controller="creative-translations"]', count: 1
      CreativeTranslationPolicy.stub :enabled?, false do
        get creatives_path(id: @creative.id)
        assert_select '[data-controller="creative-translations"]', count: 0
      end
    end
  end
end
