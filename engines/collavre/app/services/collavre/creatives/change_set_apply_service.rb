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

      private

      def build_targets(source)
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
        @targets.each_with_object([ [], [], [] ]) do |(change, snapshot), buckets|
          classify_target(change, snapshot, records, writable_ids, buckets)
        end
      end

      def locked_records
        target_ids = @targets.keys.map(&:creative_id)
        parent_ids = @targets.values.filter_map { |snapshot| snapshot["parent_id"] }
        Creative.unscoped.where(id: [ *target_ids, *parent_ids ]).order(:id).lock.index_by(&:id)
      end

      def classify_target(change, snapshot, records, writable_ids, buckets)
        plan, conflicts, skipped = buckets
        creative = records[change.creative_id]
        return classify_propagated_target(change, creative, snapshot, plan) if propagated_target?(change)
        return skipped << change.creative_id unless target_writable?(creative, snapshot, records, writable_ids)
        return if History.snapshot(creative) == snapshot

        if current_conflict?(creative, change) && resolution(change) != "force"
          resolution(change) == "skip" ? skipped << change.creative_id : conflicts << conflict_for(creative, change)
        else
          plan << [ creative, snapshot ]
        end
      end

      def retain_authorized_targets(records, writable_ids)
        visible_origins = @targets.keys.filter_map do |change|
          next unless @visible_change_ids.include?(change.id) && change.operation.in?(%w[archive unarchive])

          creative = records[change.creative_id]
          creative&.id if target_writable?(creative, @targets.fetch(change), records, writable_ids)
        end.to_set
        @propagated_attributes = PropagatedChangeAuthorization.new(
          changes: @targets.keys,
          records: records,
          writable_origin_ids: visible_origins
        ).call
        @targets.select! { |change, _snapshot| @visible_change_ids.include?(change.id) || propagated_target?(change) }
        @complete = @targets.size == @all_changes.size
      end

      def classify_propagated_target(change, creative, snapshot, plan)
        attribute = @propagated_attributes.fetch(change.id)
        current_value = History.snapshot(creative)[attribute] if creative
        return if current_value == snapshot[attribute]
        unless creative && current_value == change.public_send(source_snapshot_side)[attribute]
          @complete = false
          return
        end

        plan << [ creative, snapshot, attribute ]
      end

      def target_writable?(creative, snapshot, records, writable_ids)
        creative && !creative.read_only_source? && writable_ids.include?(creative.id) &&
          target_parent_writable?(creative, snapshot, records, writable_ids)
      end

      def revertible?(source)
        return false if source.origin == "sync" || @targets.keys.any? { |change| change.operation == "destroy" }

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
        reverse = create_reverse_set(source)
        History.track(actor: @user, origin: :revert, anchor: source.anchor_creative, anchor_source: :explicit) do
          Current.change_set = reverse
          plan.each { |creative, snapshot, propagated_attribute| apply_snapshot(creative, snapshot, propagated_attribute:) }
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
        return result(:skipped, skipped: skipped) unless skipped.empty? && @complete

        source.update!(status: "reverted") if @mode == :revert
        result(:applied)
      end

      def apply_snapshot(creative, snapshot, propagated_attribute: nil)
        return creative.update!(archived_at: Time.current) if snapshot.empty?
        return creative.update!(propagated_attribute => snapshot[propagated_attribute]) if propagated_attribute

        creative.assign_attributes(snapshot_attributes(creative, snapshot))
        creative.save!
      end

      def propagated_target?(change)
        @propagated_attributes&.key?(change.id)
      end

      def archival_transition?(change)
        change.operation.in?(%w[archive unarchive]) &&
          change.before["archived_at"] != change.after["archived_at"]
      end

      def propagated_candidate?(change)
        archival_transition?(change) || change.operation == "update"
      end

      def source_snapshot_side
        @mode == :revert ? :after : :before
      end

      def snapshot_attributes(creative, snapshot)
        data = (creative.data || {}).deep_dup
        data["content_type"] = snapshot["content_type"]
        data["editor"] = snapshot["editor"]
        data["markdown_source"] = snapshot["markdown_source"]
        {
          data: data,
          description: snapshot["content_type"] == "markdown" ?
            MarkdownConverter.markdown_to_html(snapshot["markdown_source"].to_s) : snapshot["description"],
          parent_id: snapshot["parent_id"],
          sequence: snapshot["sequence"],
          progress: snapshot["progress"],
          archived_at: snapshot["archived_at"]
        }
      end

      def result(status, change_set: nil, conflicts: [], skipped: [])
        Result.new(status: status, change_set: change_set, conflicts: conflicts, skipped: skipped)
      end
    end
  end
end
