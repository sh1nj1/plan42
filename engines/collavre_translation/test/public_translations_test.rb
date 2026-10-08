require_relative "test_helper"

module CollavreTranslation
  class PublicTranslationsTest < ActionDispatch::IntegrationTest
    include TranslationQueueTestHelper

    setup do
      use_translation_test_queue
      CollavreTranslation.model = "test-model"
      @author = users(:one)
      @author.update!(locale: "en", auto_translation_enabled: true)
      @creative = Collavre::Creative.create!(user: @author, description: "A public English document title.")
      Collavre::CreativeSharesCache.create!(creative: @creative, user: nil, permission: :read)
      @comment = @creative.comments.create!(user: users(:two), content: "A public English comment for translation.")
      @creative_url = "/translation/creatives/#{@creative.id}/translation"
      @comment_url = "/translation/comments/#{@comment.id}/translation"
    end

    teardown do
      restore_translation_queue
      CollavreTranslation.model = nil
    end

    test "anonymous readers use browser language and lang overrides for both content types" do
      [ [ @creative_url, @creative ], [ @comment_url, @comment ] ].each do |url, source|
        assert_no_difference "Translation.count" do
          get url, headers: { "Accept-Language" => "ko-KR" }
          assert_response :success
        end
        post url, headers: { "Accept-Language" => "ko-KR" }
        assert_response :success
        assert Translation.find_by(translatable: source, target_locale: "ko")
        post url, params: { lang: "en-US" }, headers: { "Accept-Language" => "ko-KR" }
        assert_response :success
        assert Translation.find_by(translatable: source, target_locale: "en")
        post url, params: { lang: "fr" }
        assert_response :unprocessable_entity
      end
    end

    test "public content follows each author setting even when the reader disables translation" do
      reader = users(:three)
      reader.update!(locale: "ko", auto_translation_enabled: false)
      sign_in_as reader, password: "password"
      [ @creative_url, @comment_url ].each do |url|
        post url
        assert_response :success
      end
      @author.update!(auto_translation_enabled: false)
      [ :get, :post ].each do |method|
        public_send(method, @creative_url)
        assert_response :forbidden
        public_send(method, @comment_url)
        assert_response :success
      end
      @comment.user.update!(auto_translation_enabled: false)
      assert_no_enqueued_jobs only: TranslateJob do
        get @comment_url
        assert_response :forbidden
        post @comment_url
        assert_response :forbidden
      end
      refute reader.reload.auto_translation_enabled?
    end

    test "public page mounts translation for anonymous and disabled readers" do
      get "/creatives", params: { id: @creative.id, lang: "ko" }
      assert_response :success
      assert_select '[data-controller="creative-translations"]', count: 1
      users(:three).update!(auto_translation_enabled: false)
      sign_in_as users(:three), password: "password"
      get "/creatives", params: { id: @creative.id }
      assert_response :success
      assert_select '[data-controller="creative-translations"]', count: 1
      assert_select '[data-controller="comment-translation-reader"]', count: 1
    end

    test "disabled readers mount translation for root and search lists" do
      reader = users(:three)
      reader.update!(locale: "ko", auto_translation_enabled: false)
      sign_in_as reader, password: "password"
      [ {}, { search: "public English document" } ].each do |params|
        get "/creatives", params: params
        assert_response :success
        assert_select '[data-controller="creative-translations"]', count: 1
        assert_select '[data-controller="comment-translation-reader"]', count: 1
      end
      get "/creatives.json", params: { search: "public English document", simple: true }
      assert_response :success
      assert_includes response.parsed_body.map { |row| row["id"] }, @creative.id
      post @creative_url
      assert_response :success
      assert Translation.for_creative(@creative, "ko")
    end

    test "disabled reader mounts translation for public child under private parent" do
      reader = users(:three)
      reader.update!(auto_translation_enabled: false)
      parent = Collavre::Creative.create!(user: reader, description: "Private parent")
      @creative.update!(parent: parent)
      refute parent.has_permission?(nil, :read)
      assert @creative.has_permission?(nil, :read)
      sign_in_as reader, password: "password"
      get "/creatives", params: { id: parent.id }
      assert_response :success
      assert_select '[data-controller="creative-translations"]', count: 1
      assert_select '[data-controller="comment-translation-reader"]', count: 1
    end

    test "disabled engine does not mount reader controllers" do
      CollavreTranslation.model = ""
      get "/creatives", params: { id: @creative.id }
      follow_redirect! if response.redirect?
      assert_response :success
      assert_select '[data-controller="creative-translations"]', count: 0
      assert_select '[data-controller="comment-translation-reader"]', count: 0
    end

    test "private comments and explicit reader denials remain inaccessible" do
      @comment.update!(private: true)
      reader = users(:three)
      Collavre::CreativeSharesCache.create!(creative: @creative, user: reader, permission: :no_access)
      sign_in_as reader, password: "password"
      [ @creative_url, @comment_url ].each do |url|
        assert_no_enqueued_jobs only: TranslateJob do
          post url
          assert_includes [ 403, 404 ], response.status
        end
      end
    end

    test "public system content without an author does not enable translation" do
      comment = Collavre::Comment.new(creative: @creative, user: nil, content: "System notice")
      refute ContentTranslationPolicy.enabled?(comment, @author)
    end

    test "anonymous readers cannot translate private comments" do
      @comment.update!(private: true)
      [ :get, :post ].each do |method|
        public_send(method, @comment_url)
        assert_response :not_found
      end
    end

    test "lang overrides signed in locale without changing the profile" do
      sign_in_as @author, password: "password"
      post @creative_url, params: { lang: "ko" }
      assert_response :success
      assert Translation.for_creative(@creative, "ko")
      assert_equal "en", @author.reload.locale
    end
  end
end
