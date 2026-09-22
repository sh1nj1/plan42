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
        @state = { "issued" => state.fetch("issued", 0).to_i + 1,
                   "floor" => state.fetch("floor", 0), "nodes" => state.fetch("nodes", {}) }
        state["issued"]
      end

      def accept?(fence, node_id)
        # Older bundles remain usable until this user starts using fences.
        return state.empty? if fence.nil?
        return false unless fence.to_s.match?(/\A[1-9]\d{0,15}\z/)

        value = fence.to_i
        nodes = state.fetch("nodes", {})
        minimum = [ state.fetch("floor", 0), nodes.fetch(node_id, 0) ].max
        return false unless value > minimum && value <= state.fetch("issued", 0)

        state["nodes"] = nodes.merge(node_id => value)
        compact
        true
      end

      private

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
