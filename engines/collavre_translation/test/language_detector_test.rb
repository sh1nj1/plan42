require_relative "test_helper"

module CollavreTranslation
  class LanguageDetectorTest < ActiveSupport::TestCase
    test "detects English and Korean with the actual local detector" do
      assert_equal "en", LanguageDetector.detect("This is a sufficiently long English sentence explaining how automatic comment translation works.")
      assert_equal "ko", LanguageDetector.detect("자동 번역 기능은 사용자의 언어 설정에 맞게 댓글을 번역하고 원문도 볼 수 있도록 제공합니다.")
    end

    test "short Hangul prose is Korean while mixed scripts stay uncertain" do
      [ "안녕", "감사합니다!", "ㅋㅋ", "한글 `code` https://example.com" ].each do |text|
        assert_equal "ko", LanguageDetector.detect(text)
      end
      [ "한글 English", "漢字", "`한글`", "@한글:" ].each do |text|
        assert_nil LanguageDetector.detect(text)
      end
    end

    test "short code URL and mention only messages stay untranslated" do
      [ "OK", "👍", "`some_long_function_name()`", "https://example.com/a_long_path @Someone:" ].each do |text|
        assert_nil LanguageDetector.detect(text)
      end
    end

    test "unreliable or low probability results stay untranslated" do
      detector = Object.new
      result = Struct.new(:language, :probability, :reliable?).new(:en, 0.7, true)
      detector.define_singleton_method(:find_language) { |_| result }
      CLD3::NNetLanguageIdentifier.stub :new, detector do
        assert_nil LanguageDetector.detect("A sufficiently long English sentence.")
        result.probability = 1.0
        result[2] = false
        assert_nil LanguageDetector.detect("A sufficiently long English sentence.")
      end
      detector.define_singleton_method(:find_language) { |_| nil }
      CLD3::NNetLanguageIdentifier.stub :new, detector do
        assert_nil LanguageDetector.detect("A sufficiently long English sentence.")
      end
    end
  end
end
