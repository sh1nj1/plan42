require_relative "test_helper"

module CollavreTranslation
  class TranslationsControllerTest < ActionDispatch::IntegrationTest
    include TranslationQueueTestHelper
    include ActionCable::TestHelper

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
      assert_select 'template[data-comment-translation-template]' do
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

    test "reader hydration gate follows the viewer preference and shared markup is neutral" do
      [ true, false ].each do |enabled|
        @user.update!(auto_translation_enabled: enabled)
        get creatives_path
        assert_response :success
        assert_select '[data-controller="comment-translation-reader"]', count: enabled ? 1 : 0
      end
      Collavre::Current.set(user: nil) do
        [ "Original broadcast", "Edited broadcast" ].each do |content|
          @comment.update!(content: content)
          html = Collavre::CommentsController.render(partial: "collavre/comments/comment",
            locals: { comment: @comment })
          assert_includes html, "data-comment-translation-template"
          refute_includes html, 'data-controller="comment-translation"'
          assert_includes html, Translation.digest(content)
        end
      end
    end

    test "real shared append and replacement broadcasts retain inert translation templates" do
      @user.update!(auto_translation_enabled: false)
      stream = Turbo::StreamsChannel.send(:stream_name_from, [ @comment.creative, :comments ])
      clear_enqueued_jobs
      Collavre::Current.set(user: nil) do
        %w[create update].each do |event|
          messages = capture_broadcasts(stream) do
            perform_enqueued_jobs(only: Turbo::Streams::ActionBroadcastJob) do
              @comment.send("broadcast_#{event}")
            end
          end
          assert_equal 1, messages.size
          html = messages.first
          assert_includes html, "action=\"#{event == 'create' ? 'append' : 'replace'}\""
          assert_includes html, "data-comment-translation-template"
          refute_includes html, 'data-controller="comment-translation"'
        end
      end
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

    test "preference defaults on and OFF preserves original without controller or jobs" do
      assert @user.auto_translation_enabled?
      @user.update!(auto_translation_enabled: false)
      get creative_comments_path(@comment.creative)
      assert_select '[data-controller="comment-translation"]', count: 0
      assert_select '[data-comment-target="content"]', text: @comment.content
      Translation.request!(@comment, "ko").update!(status: "completed", content: "Cached")
      assert_no_enqueued_jobs only: TranslateJob do
        get @url
        assert_response :forbidden
        post @url
        assert_response :forbidden
      end
      @user.update!(auto_translation_enabled: true)
      get @url
      assert_response :success
      assert_equal "Cached", response.parsed_body["content"]
    end

    test "each reader uses their own preference for the same comment" do
      @user.update!(auto_translation_enabled: false)
      reader = users(:two)
      reader.update!(locale: "ko")
      Collavre::CreativeSharesCache.create!(creative: @comment.creative, user: reader, permission: :feedback)
      get creative_comments_path(@comment.creative)
      assert_select '[data-controller="comment-translation"]', count: 0
      sign_out
      sign_in_as reader, password: "password"
      get creative_comments_path(@comment.creative)
      assert_response :success
      assert_select 'template[data-comment-translation-template]', count: 1
      assert_enqueued_jobs 1, only: TranslateJob do
        post @url
        assert_response :success
      end
      refute @user.reload.auto_translation_enabled?
      assert reader.reload.auto_translation_enabled?
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
