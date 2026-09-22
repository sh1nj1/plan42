module Collavre
  module Creatives
    # A retained floor makes eviction safe: retired requests stay stale forever.
    # The counter and floor are shared by every context and browser belonging to this user.
    class ExpansionSaveOrder
      MAX_NODES = 1_000
      attr_reader :state

      def initialize(state)
        @state = (state || {}).deep_dup
      end

      def issue
        @state = state.merge("issued" => state.fetch("issued", 0).to_i + 1,
                   "floor" => state.fetch("floor", 0), "nodes" => state.fetch("nodes", {}))
        state["issued"]
      end

      def accept?(fence, node_id, intent = nil, source = nil)
        return false unless valid_intent?(intent, source)
        # Older bundles remain usable until this user starts using fences.
        return state.empty? && intent.nil? if fence.nil?

        previous = state.fetch("intents", {}).fetch("nodes", {})[node_id]
        same_source = source.present? && intent.present? && previous.is_a?(Hash) && previous["source"] == source
        return false unless valid_fence?(fence, node_id, same_source)
        return false if same_source && intent.to_i <= previous["intent"]

        record_intent(intent, source, node_id)

        nodes = state.fetch("nodes", {})
        state["nodes"] = nodes.merge(node_id => [ fence.to_i, nodes.fetch(node_id, 0) ].max)
        compact
        true
      end

      private

      def valid_fence?(fence, node_id, same_source)
        return false unless fence.to_s.match?(/\A[1-9]\d{0,15}\z/)

        minimum = same_source ? 0 : state.fetch("nodes", {}).fetch(node_id, 0)
        fence.to_i > [ state.fetch("floor", 0), minimum ].max && fence.to_i <= state.fetch("issued", 0)
      end

      def valid_intent?(intent, source)
        return false unless source.nil? || (source.is_a?(String) && source.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/))
        intent.nil? || (intent.to_s.match?(/\A[1-9]\d{0,15}\z/) && intent.to_i <= 9_007_199_254_740_991)
      end

      def record_intent(intent, source, node_id)
        nodes = state.fetch("intents", {}).fetch("nodes", {}).dup
        nodes.delete(node_id)
        nodes[node_id] = { "source" => source, "intent" => intent.to_i } if source && intent
        nodes.shift while nodes.size > MAX_NODES
        # Remove the old global timestamp counter/floor, including on legacy writes.
        state["intents"] = { "nodes" => nodes }
      end

      def compact
        nodes = state.fetch("nodes")
        return if nodes.size <= MAX_NODES

        node_id, retired = nodes.min_by { |_, value| value }
        nodes.delete(node_id)
        state["floor"] = retired
      end
    end
  end
end
