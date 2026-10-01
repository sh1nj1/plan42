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

    test "model is opt in and stateful vendors are rejected" do
      CollavreTranslation.model = ""
      refute CollavreTranslation.enabled?
      CollavreTranslation.model = "test-model"
      CollavreTranslation.vendor = "cli_proxy"
      refute CollavreTranslation.enabled?
      CollavreTranslation.vendor = "openai"
      assert CollavreTranslation.enabled?
    end

    test "configuration uses registered shared integration settings" do
      Collavre::IntegrationSettings.stub :fetch, ->(key, **_) { key == :translation_llm_model ? "shared-model" : "google" } do
        assert_equal "shared-model", CollavreTranslation.model
        assert_equal "google", CollavreTranslation.vendor
        assert CollavreTranslation.enabled?
      end
      registry = Collavre::IntegrationSettings::Registry.instance
      assert_equal "translation", registry.find(:translation_llm_model).category
      assert_equal "google", registry.find(:translation_llm_vendor).default
      assert Collavre::ViewExtensions.for_slot(:comment_content_extensions).any? { |entry| entry[:partial].start_with?("collavre_translation/") }
    end
  end
end
