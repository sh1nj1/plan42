require "test_helper"

module CollavreOpenclaw
  # The OpenClaw adapter path in AiClientExtension#chat bypasses the base
  # Collavre::AiClient#chat (no `super`), so it must independently honor
  # @log_interactions — otherwise unsubmitted typo-correction drafts leak to
  # ActivityLog for OpenClaw-backed agents.
  class AiClientExtensionTest < ActiveSupport::TestCase
    # Minimal adapter so chat() doesn't touch the network.
    class FakeAdapter
      def initialize(**) ; end

      def chat(_messages_data, &_block)
        "ok"
      end
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
  end
end
