require_relative "test_helper"

module CollavreTranslation
  class TranslatorTest < ActiveSupport::TestCase
    test "uses tool-free AiClient with protected source and no interaction logging" do
      client = Object.new
      client.define_singleton_method(:chat) do |messages|
        raise "unmasked input" unless messages.first[:text] == "Hello COLLAVRE_TOKEN_0_END"
        "안녕하세요 COLLAVRE_TOKEN_0_END"
      end
      factory = ->(**options) do
        assert_equal "google", options[:vendor]
        assert_equal "snapshot-model", options[:model]
        assert_equal false, options[:log_interactions]
        assert_equal 60, options[:request_timeout_seconds].call
        assert_includes options[:system_prompt], "Korean"
        assert_includes options[:system_prompt], "COLLAVRE_TOKEN_<number>_END"
        client
      end
      Collavre::AiClient.stub :new, factory do
        assert_equal "안녕하세요 `code`", Translator.call("Hello `code`", "ko", vendor: "google", model: "snapshot-model")
      end
    end

    test "English target and blank provider answer" do
      client = Object.new
      client.define_singleton_method(:chat) { |_| nil }
      factory = ->(**options) do
        assert_includes options[:system_prompt], "English"
        assert_not_includes options[:system_prompt], "COLLAVRE_TOKEN"
        client
      end
      Collavre::AiClient.stub :new, factory do
        assert_raises(ArgumentError) { Translator.call("안녕하세요", "en") }
      end
    end
  end
end
