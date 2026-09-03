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
            result(:skipped, skipped: skipped)
          else
            apply(source, plan, skipped)
          end
        end
      end

      private

      def build_targets(source)
        all_changes = source.creative_changes.order(@mode == :revert ? { position: :desc } : { position: :asc })
        changes = ChangeSetVisibility.new(user: @user).changes(all_changes)
        @targets = changes.to_h { |change| [ change, @mode == :revert ? change.before : change.after ] }
        @complete = changes.size == all_changes.size
      end

      def build_plan
        records = locked_records
        writable_ids = writable_ids_for(records.keys)
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
        return skipped << change.creative_id unless target_writable?(creative, snapshot, records, writable_ids)
        return if History.snapshot(creative) == snapshot

        if current_conflict?(creative, change) && resolution(change) != "force"
          resolution(change) == "skip" ? skipped << change.creative_id : conflicts << conflict_for(creative, change)
        else
          plan << [ creative, snapshot ]
        end
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
          plan.each { |creative, snapshot| apply_snapshot(creative, snapshot) }
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

      def apply_snapshot(creative, snapshot)
        return creative.update!(archived_at: Time.current) if snapshot.empty?

        creative.assign_attributes(snapshot_attributes(creative, snapshot))
        creative.save!
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
