require_relative "test_helper"

module CollavreTranslation
  class CreativeTranslationTest < ActiveSupport::TestCase
    include TranslationQueueTestHelper

    setup do
      use_translation_test_queue
      CollavreTranslation.model = "test-model"
      @creative = Collavre::Creative.create!(user: users(:one), description: "<h1>This is an English creative title with enough text.</h1><p>English body text to translate.</p>")
    end

    teardown do
      restore_translation_queue
      CollavreTranslation.model = nil
    end

    test "creative cache is per source and locale and requests enqueue once" do
      assert_enqueued_jobs 1, only: TranslateJob do
        2.times { Translation.request!(@creative, "ko") }
      end
      record = Translation.for_creative(@creative, "ko")
      assert_nil Translation.for_creative(@creative, "en")
      @creative.update!(description: "Changed original")
      assert_nil Translation.for_creative(@creative, "ko")
      assert Translation.exists?(record.id)
    end

    test "failed creative retries are rate limited across reloads and viewers" do
      record = Translation.request!(@creative, "ko")
      record.update!(status: "failed")
      assert_no_enqueued_jobs only: TranslateJob do
        2.times { assert_equal "failed", Translation.request!(@creative, "ko").status }
      end
      travel Translation::RETRY_COOLDOWN + 1.second do
        assert_enqueued_jobs 1, only: TranslateJob do
          2.times { Translation.request!(@creative, "ko") }
        end
      end
      assert_equal "processing", record.reload.status
    end

    test "source edits bypass the failed creative cooldown" do
      record = Translation.request!(@creative, "ko")
      record.update!(status: "failed")
      @creative.update!(description: "A changed creative")
      assert_enqueued_jobs 1, only: TranslateJob do
        Translation.request!(@creative, "ko")
      end
    end

    test "job translates creative prose without changing source or AI context" do
      record = Translation.request!(@creative, "ko")
      source = @creative.description
      HtmlTranslator.stub :call, '[{"original":"English body text to translate.","translated":"번역 본문"}]' do
        TranslateJob.perform_now(record.id)
      end
      assert_equal "completed", record.reload.status
      assert_equal "번역 본문", JSON.parse(record.content).first["translated"]
      assert_equal source, @creative.reload.description
      assert_equal source, @creative.effective_description
    end

    test "short creative titles translate even when detection is uncertain" do
      @creative.update!(description: "Hello")
      record = Translation.request!(@creative, "ko")
      LanguageDetector.stub :detect, nil do
        HtmlTranslator.stub :call, '[{"original":"Hello","translated":"안녕"}]' do
          TranslateJob.perform_now(record.id)
        end
      end
      assert_equal "completed", record.reload.status
      assert_equal "안녕", JSON.parse(record.content).first["translated"]
    end

    test "protected-only creatives skip the provider and preserve their source" do
      sources = [
        '<p>https://example.com</p>', '<p>[Example Domain](https://example.com)</p>',
        '<p>`code` @Astra:</p>', '<pre>code</pre>', '<p>123 !</p>',
        '<p><span class="mention">@Astra:</span></p>'
      ]
      HtmlTranslator.stub :call, ->(*) { flunk "protected-only input must not reach provider" } do
        sources.each do |source|
          @creative.update!(description: source)
          record = Translation.request!(@creative, "ko")
          TranslateJob.perform_now(record.id)
          assert_equal "skipped", record.reload.status
          assert_nil record.content
          assert_equal source, @creative.reload.description
        end
      end
    end

    test "HTML translation restores boundary whitespace and tolerates separator whitespace changes" do
      html = "<p> 안녕 <strong>멋진</strong> 세계\t</p><p>\nLast sentence\n</p>"
      Translator.stub :call, ->(source, *) {
        assert_equal "안녕\nCOLLAVRE_TOKEN_999999_END\n멋진\nCOLLAVRE_TOKEN_999999_END\n세계\nCOLLAVRE_TOKEN_999999_END\nLast sentence", source
        "Hello COLLAVRE_TOKEN_999999_ENDwonderful\r\n COLLAVRE_TOKEN_999999_END worldCOLLAVRE_TOKEN_999999_ENDLast translated"
      } do
        result = JSON.parse(HtmlTranslator.call(html, "en"))
        assert_equal HtmlTranslator.texts(html), result.pluck("original")
        assert_equal [ " Hello ", "wonderful", " world\t", "\nLast translated\n" ], result.pluck("translated")
      end
    end

    test "creative source changed before or during translation is discarded" do
      record = Translation.request!(@creative, "ko")
      HtmlTranslator.stub :call, ->(*) { @creative.update!(description: "Changed source"); "[]" } do
        TranslateJob.perform_now(record.id)
      end
      assert_equal "skipped", record.reload.status
      assert_nil record.content
      record.update!(status: "processing")
      HtmlTranslator.stub :call, ->(*) { flunk "stale source must not be translated" } do
        TranslateJob.perform_now(record.id)
      end
      assert_equal "skipped", record.reload.status
    end

    test "linked creatives share the origin cache and deletion cleans it" do
      linked = Collavre::Creative.create!(user: users(:one), origin: @creative)
      record = Translation.request!(@creative, "ko")
      assert_equal record, Translation.for_creative(linked, "ko")
      @creative.destroy!
      refute Translation.exists?(record.id)
    end

    test "HTML translation preserves attributes and excludes code and mentions" do
      html = '<h1>English title</h1><p><a href="/path?q=1">Link label</a> <span class="mention">@Astra:</span></p><pre><code>const code = 1</code></pre>'
      Translator.stub :call, ->(source, locale, **options) {
        assert_equal "ko", locale
        assert_equal "test", options[:model]
        assert_equal "English title\nCOLLAVRE_TOKEN_999999_END\nLink label", source
        "제목\nCOLLAVRE_TOKEN_999999_END\n링크 이름"
      } do
        result = JSON.parse(HtmlTranslator.call(html, "ko", model: "test"))
        assert_equal [ "English title", "Link label" ], result.pluck("original")
        assert_equal [ "제목", "링크 이름" ], result.pluck("translated")
      end
    end

    test "HTML segment boundaries do not collide with restored source literals" do
      client = Object.new
      client.define_singleton_method(:chat) { |messages| messages.first[:text] }
      sources = [
        "COLLAVRE_TOKEN_999999_END",
        "First\nCOLLAVRE_TOKEN_999999_END\nlast",
        "COLLAVRE_TOKEN_999999_END and COLLAVRE_TOKEN_1000000_END"
      ]
      Collavre::AiClient.stub :new, client do
        sources.each do |source|
          [ "<p>#{source}</p>", "<p>#{source}</p><p>Second segment</p>" ].each do |html|
            result = JSON.parse(HtmlTranslator.call(html, "ko"))
            assert_equal HtmlTranslator.texts(html), result.pluck("original")
            assert_equal result.pluck("original"), result.pluck("translated")
          end
        end
      end
    end

    test "empty prose skips provider and changed segment boundaries fail safely" do
      Translator.stub :call, ->(*) { flunk "no prose" } do
        assert_equal "[]", HtmlTranslator.call("<pre>code</pre>", "ko")
      end
      Translator.stub :call, "broken" do
        assert_raises(ArgumentError) { HtmlTranslator.call("<p>First</p><p>Second</p>", "ko") }
      end
    end

    test "policy defaults to existing engine behavior and honors shared user gate" do
      refute CreativeTranslationPolicy.enabled?(nil)
      assert CreativeTranslationPolicy.enabled?(users(:one))
      original_gate = CollavreTranslation.method(:enabled_for?)
      allowed_user = users(:two)
      CollavreTranslation.stub :enabled_for?, ->(user) { user == allowed_user } do
        refute CreativeTranslationPolicy.enabled?(users(:one))
        assert CreativeTranslationPolicy.enabled?(users(:two))
      end
      assert_respond_to CollavreTranslation, :enabled_for?
      assert_equal original_gate, CollavreTranslation.method(:enabled_for?)
    end
  end
end
