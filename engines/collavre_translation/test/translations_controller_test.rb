require_relative "test_helper"

module CollavreTranslation
  class TranslationsControllerTest < ActionDispatch::IntegrationTest
    include TranslationQueueTestHelper

    setup do
      use_translation_test_queue
      @user = users(:one)
      @user.update!(locale: "ko")
      sign_in_as @user, password: "password"
      CollavreTranslation.model = "test-model"
      @comment = creatives(:tshirt).comments.create!(user: @user, content: "This is a sufficiently long English sentence to translate.")
      @url = "/translation/comments/#{@comment.id}/translation"
    end

    teardown do
      restore_translation_queue
      CollavreTranslation.model = nil
    end

    test "comment UI uses mounted translation URL and keeps original content" do
      get creative_comments_path(@comment.creative)
      assert_response :success
      assert_select '[data-controller="comment-translation"]' do
        assert_select '[data-comment-translation-url-value=?]', @url
      end
      assert_select '[data-comment-target="content"]', text: @comment.content
    end

    test "disabled and streaming comment UI does not mount translation controller" do
      CollavreTranslation.model = ""
      get creative_comments_path(@comment.creative)
      assert_select '[data-controller="comment-translation"]', count: 0
      CollavreTranslation.model = "test-model"
      html = Collavre::CommentsController.render(partial: "collavre/comments/comment",
        locals: { comment: @comment, streaming: true })
      refute_includes html, 'data-controller="comment-translation"'
    end

    test "GET is read only and POST enqueues once for reader locale" do
      assert_no_difference "Translation.count" do
        get @url
      end
      assert_response :success
      assert_equal "missing", response.parsed_body["status"]
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_enqueued_jobs 1, only: TranslateJob do
        2.times { post @url; assert_response :success }
      end
      assert_equal "ko", Translation.for_comment(@comment, "ko").target_locale
      record = Translation.for_comment(@comment, "ko")
      record.update!(content: "번역됨", status: "completed")
      get @url
      assert_equal "번역됨", response.parsed_body["content"]
      @comment.update!(content: "A new original")
      get @url
      assert_equal "missing", response.parsed_body["status"]
    end

    test "disabled model does not enqueue" do
      CollavreTranslation.model = ""
      assert_no_enqueued_jobs only: TranslateJob do
        post @url
      end
      assert_response :service_unavailable
    end

    test "unauthenticated readers cannot fetch cached translations" do
      sign_out
      get @url, headers: { "X-Requested-With" => "XMLHttpRequest" }
      assert_response :unauthorized
    end

    test "private comment is hidden from other readers even on readable creative" do
      @comment.update!(private: true)
      sign_out
      sign_in_as users(:two), password: "password"
      get @url
      assert_response :not_found
      assert_no_enqueued_jobs only: TranslateJob do
        post @url
      end
      assert_response :not_found
    end

    test "unreadable creative forbids both endpoints" do
      creative = Collavre::Creative.create!(user: users(:two), description: "Private creative")
      comment = creative.comments.create!(user: users(:two), content: "This is a sufficiently long English sentence.")
      url = "/translation/comments/#{comment.id}/translation"
      sign_out
      sign_in_as users(:three), password: "password"
      get url
      assert_response :forbidden
      post url
      assert_response :forbidden
    end

    test "unsupported reader locale cannot create a cache entry" do
      @user.update_column(:locale, "fr")
      post @url
      assert_response :unprocessable_entity
      assert_empty Translation.where(translatable: @comment)
    end

    test "blank locale defaults to the request locale" do
      @user.update_column(:locale, nil)
      post @url
      assert_response :success
    end
  end
end
