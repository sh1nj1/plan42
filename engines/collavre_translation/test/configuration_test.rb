require_relative "test_helper"

module CollavreTranslation
  class ConfigurationTest < ActiveSupport::TestCase
    teardown do
      CollavreTranslation.model = nil
      CollavreTranslation.vendor = nil
    end

    test "translation migration supports the minimum advertised Rails version" do
      require_relative "../db/migrate/20261001000000_create_collavre_translation_translations"

      assert_equal ActiveRecord::Migration[8.0], CreateCollavreTranslationTranslations.superclass
    end

    test "shared user gate requires reader preference and configured model" do
      user = users(:one)
      CollavreTranslation.model = "test-model"
      assert CollavreTranslation.enabled_for?(user)
      refute CollavreTranslation.enabled_for?(nil)
      user.auto_translation_enabled = false
      refute CollavreTranslation.enabled_for?(user)
      user.auto_translation_enabled = true
      CollavreTranslation.model = ""
      refute CollavreTranslation.enabled_for?(user)
      assert Collavre::User.new.auto_translation_enabled?
    end

    test "blank initializer model disables translation and stateful vendors are rejected" do
      CollavreTranslation.model = ""
      refute CollavreTranslation.enabled?
      CollavreTranslation.model = "test-model"
      CollavreTranslation.vendor = "cli_proxy"
      refute CollavreTranslation.enabled?
      CollavreTranslation.vendor = "openai"
      assert CollavreTranslation.enabled?
    end

    test "unset translation settings use the application default provider and model" do
      original = ENV.to_h.slice("COLLAVRE_DEFAULT_LLM_VENDOR", "COLLAVRE_DEFAULT_LLM_MODEL")
      ENV["COLLAVRE_DEFAULT_LLM_VENDOR"] = "openai"
      ENV["COLLAVRE_DEFAULT_LLM_MODEL"] = "shared-default-model"
      Collavre::IntegrationSettings.stub :fetch, ->(*) { nil } do
        assert_equal "openai", CollavreTranslation.vendor
        assert_equal "shared-default-model", CollavreTranslation.model
        assert CollavreTranslation.enabled?
        ENV.delete("COLLAVRE_DEFAULT_LLM_VENDOR")
        ENV.delete("COLLAVRE_DEFAULT_LLM_MODEL")
        assert_equal "gemini", CollavreTranslation.vendor
        assert_equal "gemini-3.1-flash-lite", CollavreTranslation.model
        assert CollavreTranslation.enabled?
      end
    ensure
      %w[COLLAVRE_DEFAULT_LLM_VENDOR COLLAVRE_DEFAULT_LLM_MODEL].each { |key| ENV[key] = original[key] }
    end

    test "blank application defaults fall back without disabling translation" do
      original = ENV.to_h.slice("COLLAVRE_DEFAULT_LLM_VENDOR", "COLLAVRE_DEFAULT_LLM_MODEL")
      Collavre::IntegrationSettings.stub :fetch, ->(*) { nil } do
        [ "", " \t\n" ].each do |blank|
          ENV["COLLAVRE_DEFAULT_LLM_VENDOR"] = blank
          ENV["COLLAVRE_DEFAULT_LLM_MODEL"] = blank
          assert_equal "gemini", CollavreTranslation.vendor
          assert_equal "gemini-3.1-flash-lite", CollavreTranslation.model
          assert CollavreTranslation.enabled?
        end
        CollavreTranslation.model = ""
        refute CollavreTranslation.enabled?
      end
    ensure
      %w[COLLAVRE_DEFAULT_LLM_VENDOR COLLAVRE_DEFAULT_LLM_MODEL].each { |key| ENV[key] = original[key] }
    end

    test "configuration uses registered shared integration settings" do
      Collavre::IntegrationSettings.stub :fetch, ->(key, **_) { key == :translation_llm_model ? "shared-model" : "google" } do
        assert_equal "shared-model", CollavreTranslation.model
        assert_equal "google", CollavreTranslation.vendor
        assert CollavreTranslation.enabled?
      end
      registry = Collavre::IntegrationSettings::Registry.instance
      assert_equal "translation", registry.find(:translation_llm_model).category
      assert_nil registry.find(:translation_llm_vendor).default
      assert Collavre::ViewExtensions.for_slot(:comment_content_extensions).any? { |entry| entry[:partial].start_with?("collavre_translation/") }
    end
  end
end
