require "test_helper"

module Collavre
  class FeatureCardRegistryTest < ActiveSupport::TestCase
    def teardown
      Collavre::FeatureCardRegistry.unregister(:test_card)
    end

    def register(extra = {})
      Collavre::FeatureCardRegistry.register(:test_card, {
        title_key: "collavre.comments.empty_state.cards.add_user.title",
        description_key: "collavre.comments.empty_state.cards.add_user.description"
      }.merge(extra))
    end

    test "a card without a guide renders no learn-more link and has no page" do
      card = register

      assert_not card.guide_link?
      assert_not card.builtin_guide?
      assert_not card.guide_url?
    end

    test "guide: true opts a card into the engine-provided page" do
      card = register(guide: true)

      assert card.builtin_guide?
      assert card.guide_link?
      assert_not card.guide_url?
    end

    # A vendor engine hosting its own docs still gets the link, but the engine
    # neither routes nor renders a page for it.
    test "an explicit guide_url wins over the built-in page" do
      card = register(guide: true, guide_url: "https://example.com/docs")

      assert card.guide_url?
      assert card.guide_link?
      assert_not card.builtin_guide?
    end

    test "guide_url alone is enough to render the link" do
      card = register(guide_url: "https://example.com/docs")

      assert card.guide_link?
      assert_not card.builtin_guide?
    end

    test "with_builtin_guide returns only cards backed by an engine page" do
      register(guide: true, guide_url: "https://example.com/docs")

      keys = Collavre::FeatureCardRegistry.with_builtin_guide.map(&:key)

      assert_not_includes keys, :test_card
      assert_includes keys, :mention_agent, "the core cards should all have built-in guides"
    end

    test "every core card registered by the engine has a built-in guide page" do
      keys = Collavre::FeatureCardRegistry.with_builtin_guide.map(&:key)

      %i[mention_agent slash_command chat_context automation_trigger topic_management add_user].each do |key|
        assert_includes keys, key
      end
    end
  end
end
