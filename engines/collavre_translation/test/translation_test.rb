require_relative "test_helper"

module CollavreTranslation
  class TranslationTest < ActiveSupport::TestCase
    include TranslationQueueTestHelper

    setup do
      use_translation_test_queue
      @comment = creatives(:tshirt).comments.create!(user: users(:one), content: "A sufficiently long English sentence to translate.")
    end

    teardown { restore_translation_queue }

    test "cache deduplicates requests and isolates source revisions and locales" do
      assert_enqueued_jobs 1, only: TranslateJob do
        first = Translation.request!(@comment, "ko")
        assert_equal first.id, Translation.request!(@comment, "ko").id
      end
      assert_enqueued_jobs 1, only: TranslateJob do
        Translation.request!(@comment, "en")
      end
      @comment.update!(content: "A changed English sentence which needs a fresh translation.")
      assert_nil Translation.for_comment(@comment, "ko")
      assert_enqueued_jobs 1, only: TranslateJob do
        Translation.request!(@comment, "ko")
      end
      assert_equal 3, @comment.translations.count
      @comment.destroy!
      assert_empty Translation.where(translatable_id: @comment.id)
    end

    test "enqueue failure releases claim so another request can recover" do
      TranslateJob.stub :perform_later, ->(*) { raise "queue unavailable" } do
        assert_raises(RuntimeError) { Translation.request!(@comment, "ko") }
      end
      assert_equal "pending", Translation.for_comment(@comment, "ko").status
      assert_enqueued_jobs 1, only: TranslateJob do
        assert_equal "processing", Translation.request!(@comment, "ko").status
      end
    end

    test "invalid locale and status are rejected" do
      record = Translation.new(translatable: @comment, source_digest: "digest", target_locale: "fr", status: "unknown")
      refute record.valid?
      assert record.errors[:target_locale].present?
      assert record.errors[:status].present?
    end
  end
end
