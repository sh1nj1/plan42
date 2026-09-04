# frozen_string_literal: true

module Collavre
  module Creatives
    module History
      MERGE_IDLE_WINDOW = 5.minutes
      SNAPSHOT_KEYS = %w[markdown_source content_type editor description parent_id sequence progress archived_at].freeze
      OPERATION_PRIORITY = {
        "update" => 0,
        "reorder" => 1,
        "move" => 2,
        "archive" => 3,
        "unarchive" => 3,
        "destroy" => 4,
        "create" => 5
      }.freeze

      module_function

      def track(actor:, origin:, **options)
        return yield if Current.creative_history_context || Current.agent_turn&.dig(:task)

        tracking_started = true
        previous_change_set = Current.change_set
        Current.change_set = nil
        Current.creative_history_context = context_for(options.merge(actor: actor, origin: origin))

        yield
      ensure
        if tracking_started
          discard_empty_change_set
          Current.change_set = previous_change_set
          Current.creative_history_context = nil
        end
      end

      def capture(creative)
        was_new = creative.new_record?
        before = was_new ? {} : locked_snapshot(creative)
        result = yield
        return result unless result && creative.persisted?

        after = snapshot(creative)
        record(creative, operation: operation_for(was_new, before, after), before: before, after: after)
        result
      end

      def record_bulk(creatives, operation:)
        records = creatives.to_a.sort_by(&:id)
        Creative.transaction do
          before = records.to_h { |creative| [ creative.id, locked_snapshot(creative) ] }
          result = yield
          records.each do |creative|
            creative.reload
            record(creative, operation: operation, before: before.fetch(creative.id), after: snapshot(creative))
          end
          result
        end
      end

      def record(creative, operation:, before:, after:)
        return if before == after || !recordable?

        change_set = current_change_set(creative)
        change = change_set.with_lock do
          persist_change(change_set, creative, operation, before, after)
        end
        bump_revision!(creative)
        change
      end

      def persist_change(change_set, creative, operation, before, after)
        change = change_set.creative_changes.find_or_initialize_by(creative_id: creative.id)
        if change.new_record?
          change.before = before
          change.position = next_position(change_set)
        end
        if operation.to_s.in?(%w[destroy move])
          change.previous_parent_id ||= change.before["parent_id"] || before["parent_id"]
        end
        change.after = after
        if change.persisted? && change.before == after
          stale_blob_ids = change.history_file_attachments.pluck(:blob_id)
          change.destroy!
          schedule_blob_purge_rechecks(stale_blob_ids)
          change_set.touch
          return
        end
        change.operation = merged_operation(change.operation, operation.to_s)
        change.conflict ||= {}
        change.save!
        retain_snapshot_files!(change)
        change_set.touch
        change
      end

      def retain_snapshot_files!(change)
        blobs = snapshot_signed_ids(change).filter_map do |signed_id|
          ActiveStorage::Blob.find_signed(signed_id)
        rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
          nil
        end.uniq(&:id)
        retained_ids = change.history_file_attachments.pluck(:blob_id)
        stale_attachments = change.history_file_attachments.where.not(blob_id: blobs.map(&:id))
        stale_blob_ids = stale_attachments.pluck(:blob_id)
        stale_attachments.delete_all
        schedule_blob_purge_rechecks(stale_blob_ids)
        blobs.reject { |blob| retained_ids.include?(blob.id) }.each do |blob|
          change.history_file_attachments.create!(name: "history_files", blob: blob)
        end
      end

      def schedule_blob_purge_rechecks(blob_ids)
        return if blob_ids.empty?

        ActiveRecord.after_all_transactions_commit do
          blob_ids.each { |blob_id| PurgeUnreferencedBlobJob.perform_later(blob_id) }
        end
      end

      def snapshot_signed_ids(change)
        [ change.before, change.after ].flat_map do |snapshot|
          [ snapshot["description"], snapshot["markdown_source"] ].flat_map do |markup|
            extract_signed_ids(markup)
          end
        end.uniq
      end

      def extract_signed_ids(markup)
        return [] if markup.blank?

        markup.to_s.scan(%r{/rails/active_storage/blobs/(?:redirect|proxy)/([^/?#]+)}).flatten +
          markup.to_s.scan(%r{/rails/active_storage/blobs/([^/?#]+)}).flatten +
          markup.to_s.scan(%r{/public-assets/blobs/([^/?#]+)}).flatten
      end

      def snapshot(creative, persisted: false)
        source = persisted ? creative.class.unscoped.find(creative.id) : creative
        data = source.data
        content_type = data.is_a?(Hash) ? data["content_type"] : nil
        snapshot = {
          "markdown_source" => data.is_a?(Hash) ? data["markdown_source"] : nil,
          "content_type" => content_type,
          "editor" => data.is_a?(Hash) ? data["editor"] : nil,
          "parent_id" => source.parent_id,
          "sequence" => source.sequence,
          "progress" => source.progress,
          "archived_at" => source.archived_at&.iso8601(6)
        }
        snapshot["description"] = source.description unless content_type == "markdown"
        snapshot.slice(*SNAPSHOT_KEYS)
      end

      def locked_snapshot(creative)
        snapshot(creative.class.unscoped.lock.find(creative.id))
      end

      def operation_for(was_new, before, after)
        return "create" if was_new
        return "archive" if before["archived_at"].nil? && after["archived_at"].present?
        return "unarchive" if before["archived_at"].present? && after["archived_at"].nil?
        return "move" if before["parent_id"] != after["parent_id"]
        return "reorder" if before["sequence"] != after["sequence"]

        "update"
      end

      def recordable?
        Current.creative_history_context.present? || Current.user.present?
      end

      def finish_agent_turn
        change_set = Current.change_set
        return unless change_set&.persisted? && Current.agent_turn&.dig(:task)

        if change_set.creative_changes.exists?
          workspace_user = Current.agent_turn[:user]
          if workspace_user && change_set.status == "applied" && change_set.actor_kind == "agent"
            CreativeHistoryNoticeJob.perform_later(change_set.id, workspace_user.id)
          end
        else
          change_set.destroy!
        end
      ensure
        Current.change_set = nil
      end

      def current_change_set(creative)
        Current.creative_history_context ||= inferred_context(creative)
        Current.change_set ||= find_or_create_change_set(Current.creative_history_context)
      end

      def inferred_context(creative)
        task = Current.agent_turn&.dig(:task)
        topic = task&.topic_id ? Topic.find_by(id: task.topic_id) : nil
        actor = Current.user
        origin = Current.mcp_request ? "mcp" : (task ? "tool" : "editor")
        context_for(
          actor: actor,
          origin: origin,
          anchor: topic&.creative || creative,
          anchor_source: topic ? :agent_topic : :explicit,
          task: task,
          topic: topic
        )
      end

      def context_for(attributes)
        actor = attributes[:actor]
        origin = attributes[:origin]
        {
          actor: actor,
          actor_kind: actor_kind(actor, origin),
          origin: origin.to_s,
          anchor: attributes[:anchor],
          anchor_source: attributes.fetch(:anchor_source, :none).to_s,
          task: attributes[:task],
          topic: attributes[:topic],
          summary: attributes[:summary],
          change_group_token: attributes[:change_group_token].to_s.first(255).presence,
          status: attributes.fetch(:status, "applied").to_s
        }
      end

      def actor_kind(actor, origin)
        return "sync" if origin.to_s == "sync"
        return "system" unless actor

        actor.respond_to?(:ai_user?) && actor.ai_user? ? "agent" : "human"
      end

      def find_or_create_change_set(context)
        mergeable = mergeable_human_change_set(context)
        return mergeable if mergeable

        CreativeChangeSet.create!(
          anchor_creative_id: context[:anchor]&.id,
          anchor_source: context[:anchor_source],
          user_id: context[:actor]&.id,
          actor_kind: context[:actor_kind],
          origin: context[:origin],
          task_id: context[:task]&.id,
          topic_id: context[:topic]&.id,
          status: context[:status],
          change_group_token: context[:change_group_token],
          summary: context[:summary],
          applied_at: context[:status] == "applied" ? Time.current : nil
        )
      end

      def mergeable_human_change_set(context)
        return unless context[:actor_kind] == "human" && context[:origin] == "editor"
        return unless context[:change_group_token]

        CreativeChangeSet
          .where(user_id: context[:actor]&.id, change_group_token: context[:change_group_token], status: "applied")
          .where(updated_at: MERGE_IDLE_WINDOW.ago..)
          .newest_first
          .first
      end

      def next_position(change_set)
        (change_set.creative_changes.maximum(:position) || -1) + 1
      end

      def merged_operation(existing, incoming)
        return incoming if existing.blank?

        OPERATION_PRIORITY.fetch(existing) >= OPERATION_PRIORITY.fetch(incoming) ? existing : incoming
      end

      def bump_revision!(creative)
        creative.class.increment_counter(:revision, creative.id)
        creative.revision = creative.class.unscoped.where(id: creative.id).pick(:revision)
        creative.send(:clear_attribute_change, :revision)
      end

      def discard_empty_change_set
        change_set = Current.change_set
        change_set&.destroy! if change_set&.persisted? && !change_set.creative_changes.exists?
      end
    end
  end
end
