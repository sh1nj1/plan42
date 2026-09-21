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

    test "cards default to the regular empty-chat surface" do
      card = register

      assert_equal [ :default ], card.surfaces
      assert card.visible_on?(:default)
      assert_not card.visible_on?(:inbox_system)
    end

    test "a card must have at least one surface" do
      error = assert_raises(ArgumentError) { register(surfaces: []) }

      assert_match(/at least one :surface/, error.message)
    end

    test "for selects inbox System cards without leaking regular cards" do
      inbox = Creative.inbox_for(users(:one))
      system_topic = inbox.system_topic

      keys = Collavre::FeatureCardRegistry.for(creative: inbox, topic: system_topic).map(&:key)

      assert_equal %i[inbox_notifications inbox_reply inbox_source], keys
    end

    test "for uses regular cards for non-System inbox topics" do
      inbox = Creative.inbox_for(users(:one))
      main_topic = inbox.main_topic

      keys = Collavre::FeatureCardRegistry.for(creative: inbox, topic: main_topic).map(&:key)

      assert_includes keys, :mention_agent
      assert_not_includes keys, :inbox_notifications
    end

    test "for uses regular cards for a System-named topic outside the inbox" do
      creative = creatives(:tshirt)
      topic = creative.topics.create!(name: Creative::SYSTEM_TOPIC_NAME, user: users(:one))

      keys = Collavre::FeatureCardRegistry.for(creative: creative, topic: topic).map(&:key)

      assert_includes keys, :mention_agent
      assert_not_includes keys, :inbox_notifications
    end

    test "with_builtin_guide returns only cards backed by an engine page" do
      register(guide: true, guide_url: "https://example.com/docs")

      keys = Collavre::FeatureCardRegistry.with_builtin_guide.map(&:key)

      assert_not_includes keys, :test_card
      assert_includes keys, :mention_agent, "the core cards should all have built-in guides"
    end

    # feature_path would raise UrlGenerationError for a key the features route
    # cannot accept, turning an extension's typo into a 500 on the public hub and
    # on every user's empty chat. Catch it where the author will see it.
    test "a key the features route cannot accept is rejected at registration" do
      error = assert_raises(ArgumentError) do
        Collavre::FeatureCardRegistry.register(:"vendor-card", {
          title_key: "collavre.comments.empty_state.cards.add_user.title",
          description_key: "collavre.comments.empty_state.cards.add_user.description",
          guide: true
        })
      end

      assert_match(/built-in guide page/, error.message)
    ensure
      Collavre::FeatureCardRegistry.unregister(:"vendor-card")
    end

    test "an unroutable key is fine when the card supplies its own guide_url" do
      card = Collavre::FeatureCardRegistry.register(:"vendor-card", {
        title_key: "collavre.comments.empty_state.cards.add_user.title",
        description_key: "collavre.comments.empty_state.cards.add_user.description",
        guide: true,
        guide_url: "https://example.com/docs"
      })

      assert card.guide_link?
      assert_not card.builtin_guide?
    ensure
      Collavre::FeatureCardRegistry.unregister(:"vendor-card")
    end

    test "the route constraint and the registration check use the same format" do
      route = Collavre::Engine.routes.routes.find { |r| r.name == "feature" }

      assert_equal Collavre::FeatureCard::GUIDE_KEY_FORMAT,
                   route.path.requirements[:key],
                   "routes.rb must reuse GUIDE_KEY_FORMAT so the two cannot drift"
    end

    test "every core card registered by the engine has a built-in guide page" do
      keys = Collavre::FeatureCardRegistry.with_builtin_guide.map(&:key)

      %i[
        mention_agent slash_command chat_context automation_trigger topic_management add_user
        inbox_notifications inbox_reply inbox_source
      ].each do |key|
        assert_includes keys, key
      end
    end
  end
end
