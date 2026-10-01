require_relative "test_helper"

module CollavreTranslation
  class TranslateJobTest < ActiveSupport::TestCase
    include TranslationQueueTestHelper

    setup do
      use_translation_test_queue
      CollavreTranslation.model = "test-model"
      CollavreTranslation.vendor = "google"
      @comment = creatives(:tshirt).comments.create!(user: users(:one), content: "This is a sufficiently long English sentence to translate.")
      @record = Translation.request!(@comment, "ko")
    end

    teardown do
      restore_translation_queue
      CollavreTranslation.model = nil
      CollavreTranslation.vendor = nil
    end

    test "translation requests use a dedicated worker in every environment" do
      assert_enqueued_with(job: TranslateJob, args: [ @record.id ], queue: "translations")
      config = YAML.safe_load(ERB.new(Rails.root.join("config/queue.yml").read).result, aliases: true)

      %w[development test production desktop].each do |environment|
        workers = config.fetch(environment).fetch("workers")
        translation_workers = workers.select { |worker| worker.fetch("queues").include?("translations") }
        assert_equal 1, translation_workers.size
        worker = translation_workers.first
        assert_equal [ "translations" ], worker.fetch("queues")
        assert_equal 2, worker.fetch("threads")
        assert_equal 1, worker.fetch("processes")
      end
    end

    test "completes once and leaves the original comment unchanged" do
      source = @comment.content
      calls = 0
      Translator.stub :call, ->(*) { calls += 1; "번역 결과" } do
        2.times { TranslateJob.perform_now(@record.id) }
      end
      assert_equal 1, calls
      assert_equal "completed", @record.reload.status
      assert_equal "en", @record.source_lang
      assert_equal "번역 결과", @record.content
      assert_equal "test-model", @record.llm_model
      assert_equal source, @comment.reload.content
    end

    test "persists the provider snapshot even when settings change during translation" do
      Translator.stub :call, ->(_content, _locale, vendor:, model:) {
        assert_equal "google", vendor
        assert_equal "test-model", model
        CollavreTranslation.vendor = "anthropic"
        CollavreTranslation.model = "changed-model"
        "번역 결과"
      } do
        TranslateJob.perform_now(@record.id)
      end
      assert_equal "completed", @record.reload.status
      assert_equal "google", @record.llm_vendor
      assert_equal "test-model", @record.llm_model
    end

    test "short Korean comments translate to English" do
      @comment.update!(content: "안녕")
      record = Translation.request!(@comment, "en")
      Translator.stub :call, ->(content, locale, **_options) {
        assert_equal "안녕", content
        assert_equal "en", locale
        "Hello"
      } do
        TranslateJob.perform_now(record.id)
      end
      assert_equal "completed", record.reload.status
      assert_equal "ko", record.source_lang
      assert_equal "Hello", record.content
      assert_equal "안녕", @comment.reload.content
    end

    test "disabled engine and missing records do not call provider" do
      CollavreTranslation.model = ""
      TranslateJob.perform_now(@record.id)
      assert_equal "pending", @record.reload.status
      CollavreTranslation.model = "test-model"
      assert_enqueued_with(job: TranslateJob, args: [ @record.id ]) do
        Translation.request!(@comment, "ko")
      end
      Translator.stub :call, "번역 결과" do
        TranslateJob.perform_now(@record.id)
      end
      assert_equal "completed", @record.reload.status
      assert_nil TranslateJob.perform_now(-1)
    end

    test "manual retry recovers an expired claim but leaves a live claim alone" do
      @record.update!(status: "translating")
      Translator.stub :call, ->(*) { flunk "live claim must not be stolen" } do
        TranslateJob.perform_now(@record.id)
      end
      @record.update_columns(updated_at: 6.minutes.ago)
      Translator.stub :call, "Recovered translation" do
        TranslateJob.perform_now(@record.id)
      end
      assert_equal "completed", @record.reload.status
      assert_equal "Recovered translation", @record.content
    end

    test "an expired worker cannot overwrite its replacement result or failure state" do
      [ false, true ].each do |fail_old_worker|
        @record.update!(status: "processing", content: nil)
        replacement = false
        Translator.stub :call, ->(*) {
          next "Replacement result" if replacement

          travel 6.minutes do
            Translation.for_comment(@comment, "ko")
            replacement = true
            TranslateJob.perform_now(@record.id)
          end
          raise "old provider failed" if fail_old_worker

          "Old result"
        } do
          TranslateJob.perform_now(@record.id)
        end
        assert_equal "completed", @record.reload.status
        assert_equal "Replacement result", @record.content
      end
    end

    test "source edited before job is skipped" do
      @comment.update!(content: "Edited source")
      TranslateJob.perform_now(@record.id)
      assert_equal "skipped", @record.reload.status
    end

    test "source edited during provider call discards result" do
      Translator.stub :call, ->(*) { @comment.update!(content: "Edited source"); "stale" } do
        TranslateJob.perform_now(@record.id)
      end
      assert_equal "skipped", @record.reload.status
      assert_nil @record.content
    end

    test "same-language and uncertain sources are skipped" do
      LanguageDetector.stub :detect, "ko" do
        TranslateJob.perform_now(@record.id)
      end
      assert_equal "skipped", @record.reload.status
      @record.update!(status: "processing")
      LanguageDetector.stub :detect, nil do
        TranslateJob.perform_now(@record.id)
      end
      assert_equal "skipped", @record.reload.status
    end

    test "provider failure preserves original and does not retry automatically" do
      Translator.stub :call, ->(*) { raise "provider failure" } do
        TranslateJob.perform_now(@record.id)
      end
      assert_equal "failed", @record.reload.status
      assert_nil @record.content
      assert_no_enqueued_jobs only: TranslateJob do
        Translation.request!(@comment, "ko")
      end
    end

    test "deletion during provider call discards orphaned result" do
      Translator.stub :call, ->(*) { @comment.delete; "discarded" } do
        TranslateJob.perform_now(@record.id)
      end
      refute Translation.exists?(@record.id)
    end

    test "deleted polymorphic source cleans up orphaned translation" do
      @comment.delete
      TranslateJob.perform_now(@record.id)
      refute Translation.exists?(@record.id)
    end
  end
end
