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

    test "disabled engine and missing records do not call provider" do
      CollavreTranslation.model = ""
      TranslateJob.perform_now(@record.id)
      assert_equal "skipped", @record.reload.status
      assert_nil TranslateJob.perform_now(-1)
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
