# frozen_string_literal: true

module Collavre
  module Creatives
    class ChangeSetApplyService
      Result = Struct.new(:status, :change_set, :conflicts, :skipped, keyword_init: true)

      def initialize(source:, user:, resolutions: {}, mode: :revert)
        @source = source
        @user = user
        @resolutions = resolutions.stringify_keys
        @mode = mode.to_sym
      end

      def call
        CreativeChangeSet.transaction do
          source = CreativeChangeSet.lock.find(@source.id)
          build_targets(source)
          next result(:not_revertible) unless revertible?(source)

          plan, conflicts, skipped = build_plan
          if conflicts.any?
            result(:conflict, conflicts: conflicts, skipped: skipped)
          elsif plan.empty?
            complete_noop(source, skipped)
          else
            apply(source, plan, skipped)
          end
        end
      end

      def fully_authorized?
        @authorization_only = true
        CreativeChangeSet.transaction do
          source = CreativeChangeSet.lock.find(@source.id)
          build_targets(source)
          next false unless revertible?(source)

          _plan, _conflicts, skipped = build_plan
          skipped.empty? && @complete
        end
      ensure
        @authorization_only = false
      end

      private

      def build_targets(source)
        @source_record = source
        @all_changes = source.creative_changes.order(@mode == :revert ? { position: :desc } : { position: :asc }).to_a
        visible_changes = ChangeSetVisibility.new(user: @user).changes(@all_changes)
        @visible_change_ids = visible_changes.map(&:id).to_set
        candidates = (visible_changes + @all_changes.select { |change| propagated_candidate?(change) }).uniq
        @targets = candidates.to_h { |change| [ change, @mode == :revert ? change.before : change.after ] }
      end

      def build_plan
        records = locked_records
        writable_ids = writable_ids_for(records.keys)
        retain_authorized_targets(records, writable_ids)
        @conflict_skipped_change_ids = Set.new
        @resolved_change_ids = Set.new
        buckets = @targets.each_with_object([ [], [], [] ]) do |(change, snapshot), result|
          classify_target(change, snapshot, records, writable_ids, result)
        end
        prune_skipped_dependencies(buckets.first, records) if @mode == :draft
        buckets
      end

      def locked_records
        target_ids = @targets.keys.map(&:creative_id)
        parent_ids = @targets.values.filter_map { |snapshot| snapshot["parent_id"] }
        anchor_ids = @mode == :draft ? [ @source_record.anchor_creative_id ] : []
        Creative.unscoped.where(id: [ *target_ids, *parent_ids, *anchor_ids ]).order(:id).lock.index_by(&:id)
      end

      def classify_target(change, snapshot, records, writable_ids, buckets)
        plan, conflicts, skipped = buckets
        creative = records[change.creative_id]
        return classify_draft_creation(change, snapshot, records, writable_ids, plan, skipped) if draft_creation?(change, creative)
        if propagated_target?(change) && !target_writable?(creative, snapshot, records, writable_ids, change)
          return classify_propagated_target(change, creative, snapshot, plan)
        end
        return skipped << change.creative_id unless target_writable?(creative, snapshot, records, writable_ids, change)
        return @resolved_change_ids << change.id if History.snapshot(creative) == snapshot

        if current_conflict?(creative, change) && resolution(change) != "force"
          if resolution(change) == "skip"
            @conflict_skipped_change_ids << change.id
            skipped << change.creative_id
          else
            conflicts << conflict_for(creative, change)
          end
        else
          plan << [ creative, snapshot, @propagated_attributes[change.id], change ]
        end
      end

      def classify_draft_creation(change, snapshot, records, writable_ids, plan, skipped)
        parent_id = snapshot["parent_id"]
        writable = if parent_id.nil?
                     writable_parent?(records[@source_record.anchor_creative_id], writable_ids)
        elsif parent_id.negative?
                     virtual_creation_ids.include?(parent_id)
        else
                     parent = records[parent_id]
                     parent && writable_parent?(parent, writable_ids)
        end
        writable ? plan << [ nil, snapshot, nil, change ] : skipped << change.creative_id
      end

      def retain_authorized_targets(records, writable_ids)
        writable_sources = @targets.keys.filter_map do |change|
          next unless @visible_change_ids.include?(change.id)
          next unless archival_transition?(change) || progress_transition?(change)

          creative = records[change.creative_id]
          creative&.id if target_writable?(creative, @targets.fetch(change), records, writable_ids, change)
        end.to_set
        @propagated_attributes = PropagatedChangeAuthorization.new(
          changes: @targets.keys,
          records: records,
          writable_source_ids: writable_sources
        ).call
        @targets.select! { |change, _snapshot| @visible_change_ids.include?(change.id) || propagated_target?(change) }
        @complete = @targets.size == @all_changes.size
      end

      def classify_propagated_target(change, creative, snapshot, plan)
        attributes = Array(@propagated_attributes.fetch(change.id))
        current_values = History.snapshot(creative).slice(*attributes) if creative
        return @resolved_change_ids << change.id if current_values == snapshot.slice(*attributes)
        unless creative && current_values == change.public_send(source_snapshot_side).slice(*attributes)
          @complete = false unless @authorization_only
          return
        end

        plan << [ creative, snapshot, attributes, change ]
      end

      def target_writable?(creative, snapshot, records, writable_ids, change)
        creative && (!creative.read_only_source? || change.archive_propagation_only?) && writable_ids.include?(creative.id) &&
          (@authorization_only || target_parent_writable?(creative, snapshot, records, writable_ids))
      end

      def revertible?(source)
        return false if source.origin == "sync" || @targets.keys.any? { |change| change.operation == "destroy" }

        return source.status == "draft" if @mode == :draft

        @mode == :restore ? source.status.in?(%w[applied reverted]) : source.status == "applied"
      end

      def writable_ids_for(ids)
        PermissionFilter.new(user: @user)
          .readable_ids(ids, min_permission: :write).to_set
      end

      def target_parent_writable?(creative, snapshot, records, writable_ids)
        parent_id = snapshot["parent_id"]
        return true if parent_id.nil? || parent_id == creative.parent_id

        parent = records[parent_id]
        writable_parent?(parent, writable_ids) && !parent.self_and_ancestors.exists?(id: creative.id)
      end

      def writable_parent?(parent, writable_ids)
        parent && !parent.read_only_source? && writable_ids.include?(parent.id)
      end

      def current_conflict?(creative, change)
        return History.snapshot(creative) != change.before if @mode == :draft
        return false if @mode == :restore

        History.snapshot(creative) != change.after
      end

      def resolution(change)
        @resolutions[change.creative_id.to_s]
      end

      def conflict_for(creative, change)
        {
          creative_id: creative.id,
          expected_revision: change.after,
          current_revision: History.snapshot(creative)
        }
      end

      def apply(source, plan, skipped)
        return apply_draft(source, plan, skipped) if @mode == :draft

        reverse = create_reverse_set(source)
        History.track(actor: @user, origin: :revert, anchor: source.anchor_creative, anchor_source: :explicit) do
          Current.change_set = reverse
          plan.each { |creative, snapshot, propagated_attribute, _change| apply_snapshot(creative, snapshot, propagated_attribute:) }
        end
        source.update!(status: "reverted", reverted_by: reverse) if @mode == :revert && skipped.empty? && @complete
        status = skipped.empty? && @complete ? :applied : :partial
        result(status, change_set: reverse, skipped: skipped)
      end

      def create_reverse_set(source)
        CreativeChangeSet.create!(
          anchor_creative: source.anchor_creative,
          anchor_source: source.anchor_source || "explicit",
          user: @user,
          actor_kind: @user&.ai_user? ? "agent" : "human",
          origin: "revert",
          status: "applied",
          reverts: @mode == :revert ? source : nil,
          applied_at: Time.current
        )
      end

      def complete_noop(source, skipped)
        return reject_fully_skipped_draft(source, skipped) if fully_skipped_draft?(skipped)
        return apply_draft(source, [], skipped) if resolved_skipped_draft?(skipped)
        return result(:skipped, skipped: skipped) unless skipped.empty? && @complete

        if @mode == :revert
          source.update!(status: "reverted")
        elsif @mode == :draft
          source.update!(status: "applied", applied_at: Time.current)
        end
        result(:applied)
      end

      def apply_draft(source, plan, skipped)
        return result(:skipped, skipped: skipped) unless @complete && only_conflicts_skipped?(skipped)

        DraftChangeSetApplicator.new(
          change_set: source, user: @user, plan: plan, skipped_change_ids: @draft_discard_change_ids
        ).call
        status = skipped.empty? ? :applied : :partial
        result(status, change_set: source, skipped: skipped)
      end

      def apply_snapshot(creative, snapshot, propagated_attribute: nil)
        return creative.update!(archived_at: Time.current) if snapshot.empty?
        return creative.update!(snapshot.slice(*Array(propagated_attribute))) if propagated_attribute

        SnapshotAssignment.call(creative, snapshot)
        creative.save!
      end

      def propagated_target?(change)
        @propagated_attributes&.key?(change.id)
      end

      def archival_transition?(change)
        change.operation.in?(%w[archive unarchive]) &&
          change.before["archived_at"] != change.after["archived_at"]
      end

      def progress_transition?(change)
        change.before["progress"] != change.after["progress"]
      end

      def propagated_candidate?(change)
        archival_transition?(change) || change.operation == "update"
      end

      def source_snapshot_side
        @mode == :revert ? :after : :before
      end

      def draft_creation?(change, creative)
        @mode == :draft && creative.nil? && change.before.empty?
      end

      def virtual_creation_ids
        @virtual_creation_ids ||= @targets.keys.select { |change| change.before.empty? }.map(&:creative_id).to_set
      end

      def only_conflicts_skipped?(ids)
        conflict_ids = @all_changes.select { |change| @conflict_skipped_change_ids.include?(change.id) }
          .map(&:creative_id).to_set
        ids.to_set == conflict_ids
      end

      def fully_skipped_draft?(skipped)
        @mode == :draft && @complete && skipped.present? && only_conflicts_skipped?(skipped) &&
          @draft_discard_change_ids.size == @all_changes.size
      end

      def resolved_skipped_draft?(skipped)
        return false unless @mode == :draft && @complete && skipped.present? && only_conflicts_skipped?(skipped)

        (@draft_discard_change_ids | @resolved_change_ids).size == @all_changes.size
      end

      def reject_fully_skipped_draft(source, skipped)
        source.update!(status: "rejected")
        result(:rejected, change_set: source, skipped: skipped)
      end

      def prune_skipped_dependencies(plan, records)
        @draft_discard_change_ids = DraftConflictDependencyPruner.new(
          changes: @all_changes, records: records, skipped_change_ids: @conflict_skipped_change_ids
        ).call(plan)
      end

      def result(status, change_set: nil, conflicts: [], skipped: [])
        Result.new(status: status, change_set: change_set, conflicts: conflicts, skipped: skipped)
      end
    end
  end
end
