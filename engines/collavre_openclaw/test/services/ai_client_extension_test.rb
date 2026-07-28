require "test_helper"

module CollavreOpenclaw
  # The OpenClaw adapter path in AiClientExtension#chat bypasses the base
  # Collavre::AiClient#chat (no `super`), so it must independently honor
  # @log_interactions — otherwise unsubmitted typo-correction drafts leak to
  # ActivityLog for OpenClaw-backed agents.
  class AiClientExtensionTest < ActiveSupport::TestCase
    # Minimal adapter so chat() doesn't touch the network. It tracks
    # last_handoff_failed? because the real one does: a double that does not
    # follow its collaborator is how a seam stops being tested.
    class FakeAdapter
      def initialize(**) ; end

      def chat(_messages_data, &_block)
        "ok"
      end

      def last_handoff_failed? = false
      def handed_off? = true
    end

    # The failures the adapter converts into a streamed error plus nil:
    # missing credentials, a gateway that cannot be reached.
    class FailingAdapter
      def initialize(**) ; end

      def chat(_messages_data, &block)
        block&.call("Error: OpenClaw Gateway URL not configured")
        nil
      end

      def last_handoff_failed? = true
      def handed_off? = false
    end

    # The one path that skips the propagation: the extension re-raises.
    class RaisingAdapter
      def initialize(**) ; end

      def chat(_messages_data, &_block)
        raise "gateway blew up"
      end

      def last_handoff_failed? = true
      def handed_off? = false
    end

    setup do
      Collavre::AiClient.register_adapter("faketest", FakeAdapter)
    end

    teardown do
      Collavre::AiClient.adapter_registry.delete("faketest")
    end

    def build_client(log_interactions:)
      Collavre::AiClient.new(
        vendor: "faketest",
        model: "m",
        system_prompt: "s",
        log_interactions: log_interactions
      )
    end

    def messages
      [ { role: :user, parts: [ { text: "안녀하세요" } ] } ]
    end

    test "does not log the interaction when log_interactions is false" do
      client = build_client(log_interactions: false)
      logged = false
      client.define_singleton_method(:log_interaction) { |**| logged = true }

      client.chat(messages)

      assert_not logged, "draft must not be persisted to ActivityLog on the adapter path"
    end

    test "logs the interaction when log_interactions is true (default behavior)" do
      client = build_client(log_interactions: true)
      logged = false
      client.define_singleton_method(:log_interaction) { |**| logged = true }

      client.chat(messages)

      assert logged, "normal adapter calls must still be logged"
    end

    # AiAgentService asks the client, not the adapter, and marks the turn's
    # DeliveryRecord off the answer. This path never calls super, so the base
    # #chat that sets the flag never runs — without propagating it here, an
    # OpenClaw turn whose request never left the building still ends `done`
    # with the flag down, and the dispatches dropped against it stay dropped.
    test "a failed handoff on the adapter path reaches the client" do
      Collavre::AiClient.register_adapter("failingtest", FailingAdapter)
      client = Collavre::AiClient.new(
        vendor: "failingtest", model: "m", system_prompt: "s", log_interactions: false
      )

      assert_nil client.chat(messages)
      assert_predicate client, :last_handoff_failed?
    ensure
      Collavre::AiClient.adapter_registry.delete("failingtest")
    end

    test "an adapter that answered leaves the flag down" do
      client = build_client(log_interactions: false)

      assert_equal "ok", client.chat(messages)
      assert_not client.last_handoff_failed?
    end

    # The same seam, positively: a turn the user stops mid-answer never reaches
    # the line that sets the flag above, so the cancelled ending is read off
    # this instead. It has to travel the same way, and be this chat's answer
    # rather than the previous one's.
    test "a handoff on the adapter path reaches the client" do
      client = build_client(log_interactions: false)

      assert_equal "ok", client.chat(messages)
      assert_predicate client, :handed_off?, "premise: the chat before it did hand over"

      # Same client, next chat: a client is reused across a turn's calls, so an
      # answer left standing would exempt every later one.
      Collavre::AiClient.register_adapter("faketest", FailingAdapter)
      assert_nil client.chat(messages)
      assert_not client.handed_off?
    end

    # Control: the flag describes the *last* chat, and a chat that raised did
    # not answer the question — the exception is what ends the turn, and
    # AiAgentJob marks it `failed`, an ending the restore already reads. What
    # must not happen is the previous chat's failure standing in for this one,
    # which is the one path that skips the propagation above. Base #chat clears
    # it on the way in for the same reason; this branch never reaches `super`.
    test "a chat that raised does not leave the flag standing from the one before" do
      Collavre::AiClient.register_adapter("failingtest", FailingAdapter)
      client = Collavre::AiClient.new(
        vendor: "failingtest", model: "m", system_prompt: "s", log_interactions: false
      )
      client.chat(messages)
      assert_predicate client, :last_handoff_failed?, "premise: the chat before it failed to hand over"
      Collavre::AiClient.register_adapter("failingtest", RaisingAdapter)

      assert_raises(RuntimeError) { client.chat(messages) }

      assert_not client.last_handoff_failed?
    ensure
      Collavre::AiClient.adapter_registry.delete("failingtest")
    end
  end
end
