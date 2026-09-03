# frozen_string_literal: true

module Collavre
  module Creatives
    class ChangeSetApplyService
      Result = Struct.new(:status, :change_set, :conflicts, :skipped, keyword_init: true)

      def initialize(source:, user:, targets:, resolutions: {}, mode: :revert)
        @source = source
        @user = user
        @targets = targets
        @resolutions = resolutions.stringify_keys
        @mode = mode.to_sym
      end

      def call
        CreativeChangeSet.transaction do
          source = CreativeChangeSet.lock.find(@source.id)
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

      def build_plan
        plan = []
        conflicts = []
        skipped = []
        creatives = Creative.unscoped.where(id: @targets.keys.map(&:creative_id)).order(:id).lock.index_by(&:id)
        @targets.each do |change, snapshot|
          creative = creatives[change.creative_id]
          if creative.nil? || !creative.has_permission?(@user, :write)
            skipped << change.creative_id
          elsif History.snapshot(creative) == snapshot
            next
          elsif current_conflict?(creative, change) && resolution(change) != "force"
            resolution(change) == "skip" ? skipped << change.creative_id : conflicts << conflict_for(creative, change)
          else
            plan << [ creative, snapshot ]
          end
        end
        [ plan, conflicts, skipped ]
      end

      def revertible?(source)
        return false if source.origin == "sync"

        @mode == :restore ? source.status.in?(%w[applied reverted]) : source.status == "applied"
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
        source.update!(status: "reverted", reverted_by: reverse) if @mode == :revert
        result(:applied, change_set: reverse, skipped: skipped)
      end

      def create_reverse_set(source)
        CreativeChangeSet.create!(
          anchor_creative: source.anchor_creative,
          anchor_source: source.anchor_source || "explicit",
          user: @user,
          actor_kind: @user&.ai_user? ? "agent" : "human",
          origin: "revert",
          status: "applied",
          reverts: source,
          summary: source.summary,
          applied_at: Time.current
        )
      end

      def apply_snapshot(creative, snapshot)
        return creative.update!(archived_at: Time.current) if snapshot.empty?

        creative.skip_read_only_source_validation = true
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
