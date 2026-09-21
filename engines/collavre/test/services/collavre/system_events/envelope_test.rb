require "test_helper"

module Collavre
  module SystemEvents
    class EnvelopeTest < ActiveSupport::TestCase
      test "a root is its own correlation at depth zero" do
        envelope = Envelope.root("comment_created", source: "comment_callback")

        assert_equal envelope.id, envelope.correlation_id
        assert_nil envelope.causation_id
        assert_equal 0, envelope.depth
        assert_equal "comment_callback", envelope.source
        assert envelope.root?
        assert_match(/\A\d{4}-\d{2}-\d{2}T/, envelope.occurred_at)
      end

      test "a child advances depth and retains its causal chain" do
        parent = Envelope.root("comment_created", source: "comment_callback")
        child = Envelope.child("comment_created", parent: parent.to_h, source: "a2a")

        assert_not_equal parent.id, child.id
        assert_equal parent.correlation_id, child.correlation_id
        assert_equal parent.id, child.causation_id
        assert_equal 1, child.depth
        assert_equal "a2a", child.source
        assert_not child.root?
      end

      test "an absent or invalid parent falls back to a root" do
        [ nil, "not a hash", {} ].each do |parent|
          envelope = Envelope.child("comment_created", parent: parent, source: nil)

          assert envelope.root?
          assert_equal envelope.id, envelope.correlation_id
          assert_equal Envelope::UNKNOWN_SOURCE, envelope.source
        end
      end

      test "it round trips through JSON with string keys" do
        envelope = Envelope.root("comment_created", source: "cron")
        restored = Envelope.from(JSON.parse(envelope.to_h.to_json))

        assert_equal envelope, restored
        assert_equal %w[causation_id correlation_id depth id name occurred_at source], envelope.to_h.keys.sort
        assert envelope.to_h.keys.all? { |key| key.is_a?(String) }
      end

      test "from tolerates incomplete data and in reads either key form" do
        envelope = Envelope.root("comment_created", source: "cron")

        assert_nil Envelope.from(nil)
        assert_nil Envelope.from({ "name" => "comment_created" })
        restored = Envelope.from({ "id" => "evt-1", "name" => "comment_created" })
        assert_equal "evt-1", restored.correlation_id
        assert_equal 0, restored.depth
        assert_equal envelope, Envelope.in({ "event" => envelope.to_h })
        assert_equal envelope, Envelope.in({ event: envelope.to_h })
        assert_nil Envelope.in(nil)
      end

      test "constants belong to Envelope rather than SystemEvents" do
        assert_equal "event", Envelope::KEY
        assert_not Collavre::SystemEvents.const_defined?(:KEY, false)
      end
    end
  end
end
