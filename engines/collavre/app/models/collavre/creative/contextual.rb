module Collavre
  class Creative < ApplicationRecord
    # Context creatives injected into AI prompts: direct and inherited IDs, the
    # disabled set, and the user-arranged display/injection order.
    module Contextual
      extend ActiveSupport::Concern

      # Returns the directly-configured context creative IDs for this creative.
      def context_ids
        data.is_a?(Hash) ? Array(data["context_ids"]) : []
      end

      # Returns the directly-configured disabled context IDs for this creative.
      def disabled_context_ids
        data.is_a?(Hash) ? Array(data["disabled_context_ids"]) : []
      end

      # Returns the effective context IDs: own + inherited from ancestors (deduplicated).
      def effective_context_ids(visited_ids = Set.new)
        return [] if visited_ids.include?(id)

        visited_ids.add(id)
        own = context_ids
        parent_ctx = parent&.effective_context_ids(visited_ids) || []
        (own + parent_ctx).uniq
      end

      # Returns the effective disabled context IDs: own + inherited from ancestors (deduplicated).
      def effective_disabled_context_ids(visited_ids = Set.new)
        return [] if visited_ids.include?(id)

        visited_ids.add(id)
        own = disabled_context_ids
        parent_disabled = parent&.effective_disabled_context_ids(visited_ids) || []
        (own + parent_disabled).uniq
      end

      # Returns the user-arranged context order saved on this creative.
      def context_order
        data.is_a?(Hash) ? context_id_list(data["context_order"]) : []
      end

      # Returns effective context IDs (excluding self) in the order shown in the
      # chat context bar and injected into AI prompts. Ancestors' arrangement
      # always wins: contexts inherited from the parent keep the parent's order,
      # and only contexts newly added on this creative follow its own saved
      # order (they may sit between inherited ones).
      def ordered_context_ids
        arranged_context_ids(Set.new, id)
      end

      # Contexts arranged by ancestors; their order cannot be changed here.
      def inherited_ordered_context_ids
        parent&.arranged_context_ids(Set[id]) || []
      end

      # Returns context creatives (excludes self to avoid duplication).
      def context_creatives
        ids = effective_context_ids
        ids -= [ id ]
        Creative.where(id: ids)
      end

      # Applies the chat context bar settings present in +settings+ (context_ids,
      # context_order, disabled_context_ids, disabled_self_context). The row is
      # locked and reloaded first so concurrent requests (e.g. another tab
      # removing a context while this one reorders) merge into the latest data
      # instead of overwriting it with a stale copy.
      def update_context_settings(settings)
        settings = settings.to_h.with_indifferent_access
        with_lock { update(data: context_settings_data(settings)) }
      end

      protected

      # +hidden_id+ (the viewing creative itself) is dropped before slots are
      # assigned, so a hidden inherited ID cannot take a visible context's slot.
      def arranged_context_ids(visited_ids = Set.new, hidden_id = nil)
        return [] if visited_ids.include?(id)

        visited_ids.add(id)
        inherited = (parent&.arranged_context_ids(visited_ids) || []) - [ hidden_id ]
        arrange_own_contexts(inherited, context_id_list(context_ids) - inherited - [ hidden_id ])
      end

      private

      # Sorts by this creative's saved order to pick the slots of its own new
      # contexts, then refills the remaining slots with the inherited contexts
      # in the ancestors' order.
      def arrange_own_contexts(inherited, own_new)
        order = context_order
        return inherited + own_new if order.empty? || own_new.empty?

        rank = order.each_with_index.to_h
        slots = (inherited + own_new).each_with_index.sort_by { |cid, index| [ rank.fetch(cid, order.size), index ] }
        queue = inherited.dup
        slots.map { |cid, _| own_new.include?(cid) ? cid : queue.shift }
      end

      def context_settings_data(settings)
        new_data = (data || {}).dup
        apply_context_ids_setting(new_data, settings) if settings.key?(:context_ids)
        apply_context_order_setting(new_data, settings[:context_order]) if settings.key?(:context_order)
        new_data.delete("context_order") if new_data.key?("context_order") && new_data["context_order"].empty?
        apply_disabled_context_setting(new_data, settings[:disabled_context_ids]) if settings.key?(:disabled_context_ids)
        apply_disabled_self_context_setting(new_data, settings[:disabled_self_context]) if settings.key?(:disabled_self_context)
        new_data
      end

      # Metadata is free-form JSON, so drop anything that is not a positive ID.
      def context_id_list(values)
        Array(values).filter_map { |v| v.to_i if v.is_a?(Integer) || v.to_s.match?(/\A\d+\z/) }.select(&:positive?).uniq
      end

      # Keeps only IDs that are still effective contexts under the lock, so a
      # stale reorder from another tab cannot resurrect a just-removed context.
      def apply_context_order_setting(new_data, requested)
        own_ids = context_id_list(new_data["context_ids"])
        effective = own_ids + (parent&.effective_context_ids || []).map(&:to_i)
        new_data["context_order"] = context_id_list(requested) & effective
      end

      # A removed context must not keep its old slot in context_order, or
      # re-adding it later would restore that slot instead of appending it.
      # IDs still inherited from an ancestor remain visible, so they keep theirs.
      def apply_context_ids_setting(new_data, settings)
        new_ids = Array(settings[:context_ids]).map(&:to_i)
        removed_ids = context_ids.map(&:to_i) - new_ids - (parent&.effective_context_ids || []).map(&:to_i)
        new_data["context_order"] = context_order - removed_ids if removed_ids.any? && new_data.key?("context_order")
        new_data["context_ids"] = new_ids
      end

      # Only this creative's own disabled IDs are stored; ones inherited from
      # ancestors stay with the ancestor.
      def apply_disabled_context_setting(new_data, requested)
        parent_disabled = parent&.effective_disabled_context_ids || []
        inherited_only = parent_disabled - disabled_context_ids
        new_data["disabled_context_ids"] = Array(requested).map(&:to_i) - inherited_only
        new_data.delete("disabled_context_ids") if new_data["disabled_context_ids"].empty?
      end

      def apply_disabled_self_context_setting(new_data, value)
        if ActiveModel::Type::Boolean.new.cast(value)
          new_data["disabled_self_context"] = true
        else
          new_data.delete("disabled_self_context")
        end
      end
    end
  end
end
