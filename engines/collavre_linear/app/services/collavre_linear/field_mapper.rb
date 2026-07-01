# frozen_string_literal: true

module CollavreLinear
  # Pure field translation between Collavre Creative attributes and Linear issue
  # attributes.  NO I/O — this class never reads from the DB or makes HTTP calls.
  #
  # == priority <-> sequence mapping (locked product decision)
  #
  # Linear priority is a 5-value enum:
  #   0 = No priority, 1 = Urgent, 2 = High, 3 = Medium, 4 = Low
  #
  # Collavre sequence is a dense, ZERO-BASED total order of siblings (closure_tree):
  # core resequencing (`CreateService#resequence`, `Reorderer#resequence!`) assigns
  # `each_with_index`, so the first sibling is sequence 0. The mapping must honor
  # that base — otherwise the first (top-ranked) sibling would export as "None".
  #
  # Inbound  (Linear → Collavre): sequence = (priority == 0 ? 4 : priority - 1)
  #   Urgent(1) → 0 (first), Low(4) → 3, None(0) → 4 (after all ranked buckets).
  #
  # Outbound (Collavre → Linear): sequence 0-3 maps to priority 1-4 (0→Urgent);
  #   sequence 4 (the "None" sentinel) and nil/unranked → priority 0 (None).
  #
  # Lossy edge: Linear priority is a 5-bucket enum; Collavre sequence is a dense
  # integer total order.  Within-bucket ordering is NOT representable in Linear
  # priority — only the bucket (1-4) is preserved.  The Task 10 applier must
  # write the computed sequence via closure_tree's reorder path, not a raw column
  # update, because closure_tree maintains sibling order invariants.
  module FieldMapper
    module_function

    # Outbound: Creative → Linear issue attributes.
    #
    # @param creative [#title, #description, #sequence, #data] — a Creative
    #   (or compatible stub).  Must NOT expose #progress; the mapper never reads it.
    # @return [Hash] with keys: :title, :description, :priority, and optionally
    #   :state_id and :label_ids (omitted when not set).
    def creative_to_issue_attrs(creative)
      attrs = {
        title:       creative.title,
        description: creative.description,
        priority:    sequence_to_priority(creative.sequence)
      }

      linear_data = (creative.data || {})["linear"] || {}

      if (state = linear_data["state"])
        attrs[:state_id] = state["id"]
      end

      if (labels = linear_data["labels"]) && labels.any?
        attrs[:label_ids] = labels.map { |l| l["id"] }
      end

      attrs
    end

    # Inbound: Linear issue payload → Collavre creative attributes.
    #
    # @param issue_payload [Hash] — a raw Linear issue hash (string keys), e.g.
    #   from a webhook or API response.  Expected keys: "title", "description",
    #   "priority", "state", "labels" ({"nodes" => [...]}), "assignee".
    # @return [Hash] with keys: :title, :description, :sequence,
    #   :data_linear ({state:, labels:, assignee:}).
    #   Never contains :progress.
    def issue_to_creative_attrs(issue_payload)
      priority = issue_payload["priority"].to_i

      {
        title:       issue_payload["title"],
        description: issue_payload["description"],
        sequence:    priority_to_sequence(priority),
        data_linear: {
          state:    issue_payload["state"],
          labels:   (issue_payload.dig("labels", "nodes") || []),
          assignee: issue_payload["assignee"]
        }
      }
    end

    # -- Private helpers -------------------------------------------------------

    # Map a creative's ZERO-BASED sequence integer to a Linear priority (0-4).
    #
    # sequence 0-3      → 1-4 (0→Urgent, 3→Low)
    # sequence 4        → 0   (the None sentinel, sorts after all ranked buckets)
    # sequence nil or >4 → 0  (unranked / out-of-range → No priority)
    def sequence_to_priority(sequence)
      return 0 if sequence.nil?
      return 0 if sequence < 0 || sequence > 3

      sequence + 1
    end
    private_class_method :sequence_to_priority

    # Map a Linear priority integer to a Collavre ZERO-BASED sequence integer.
    #
    # priority 1-4 → 0-3 (Urgent→0, Low→3)
    # priority 0   → 4   (None sentinel, sorts last among siblings)
    def priority_to_sequence(priority)
      priority == 0 ? 4 : priority - 1
    end
    private_class_method :priority_to_sequence
  end
end
