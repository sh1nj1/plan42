require "test_helper"

module Collavre
  module SystemEvents
    class VocabularyTest < ActiveSupport::TestCase
      test "comment_created is registered with its payload shape and sources" do
        definition = Vocabulary.fetch(:comment_created)

        assert Vocabulary.known?("comment_created")
        assert_includes Vocabulary.names, "comment_created"
        assert_equal %w[comment creative], definition.required_keys
        assert_includes definition.sources, "comment_callback"
        assert_includes definition.sources, "a2a"
      end

      test "an unregistered event raises and is not known" do
        error = assert_raises(Vocabulary::UnknownEvent) { Vocabulary.fetch("deploy_requested") }

        assert_match(/deploy_requested/, error.message)
        assert_match(/comment_created/, error.message)
        assert_not Vocabulary.known?("deploy_requested")
        assert_not Vocabulary.known?(nil)
      end

      test "missing keys accepts symbol or string payload keys and treats nil as absent" do
        assert_equal %w[creative], Vocabulary.missing_keys("comment_created", { "comment" => {} })
        assert_empty Vocabulary.missing_keys("comment_created", { comment: {}, creative: {} })
        assert_equal %w[creative], Vocabulary.missing_keys(
          "comment_created", { "comment" => {}, "creative" => nil }
        )
      end

      test "an unknown event has no declared missing payload keys" do
        assert_empty Vocabulary.missing_keys("deploy_requested", {})
        assert Vocabulary::EVENTS.frozen?
      end
    end
  end
end
