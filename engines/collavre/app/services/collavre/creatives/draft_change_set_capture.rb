# frozen_string_literal: true

module Collavre
  module Creatives
    class DraftChangeSetCapture
      CHANGE_SET_KEYS = %w[anchor_creative_id anchor_source user_id actor_kind origin task_id topic_id
                           change_group_token summary].freeze
      CHANGE_KEYS = %w[creative_id previous_parent_id operation before after position conflict].freeze

      def initialize(anchor:, origin:, summary: nil)
        @anchor = anchor
        @origin = origin.to_s
        @summary = summary
        @actor = Current.user
        @agent_turn = Current.agent_turn
      end

      def call(&operation)
        task = current_task
        return capture_and_persist(&operation) unless task

        task.with_lock { capture_and_persist(&operation) }
      end

      private

      def capture_and_persist
        return pending_result(existing_draft) if existing_draft

        payload = capture { yield }
        return payload.fetch(:result) unless payload[:change_set]

        draft = persist(payload)
        pending_result(draft)
      end

      def existing_draft
        CreativeChangeSet.find_by(task_id: current_task&.id, status: "draft") if current_task
      end

      def current_task = @agent_turn&.dig(:task)

      def capture
        payload = { result: nil, change_set: nil, changes: nil, blobs: [] }
        ApplicationRecord.transaction(requires_new: true) do
          Current.set(user: @actor, agent_turn: nil, mcp_request: nil, change_set: nil, creative_history_context: nil) do
            History.track(**history_context) do
              payload[:result] = yield
              serialize_capture(payload) if payload[:result]&.dig(:success)
            end
          end
          raise ActiveRecord::Rollback
        end
        payload
      end

      def history_context
        {
          actor: @actor,
          origin: @origin,
          anchor: @anchor,
          anchor_source: anchor_source,
          task: current_task,
          topic: current_task&.topic_id ? Topic.find_by(id: current_task.topic_id) : nil,
          summary: @summary,
          status: "draft"
        }
      end

      def anchor_source
        return :import_target if @origin == "import"

        current_task ? :agent_topic : :explicit
      end

      def serialize_capture(payload)
        change_set = Current.change_set
        return unless change_set&.creative_changes&.exists?

        changes = change_set.creative_changes.order(:position).to_a
        payload[:change_set] = change_set.attributes.slice(*CHANGE_SET_KEYS)
        payload[:changes] = changes.map { |change| serialized_change(change) }
        payload[:blobs] = added_snapshot_blobs(changes)
      end

      def serialized_change(change)
        attributes = change.attributes.slice(*CHANGE_KEYS)
        return attributes if change.before.empty? || change.before["progress"] == change.after["progress"]

        creative = Creative.unscoped.find_by(id: change.creative_id)
        return attributes unless creative

        target_ids = ProgressPropagationTargets.new(creative.effective_origin).call.map(&:id)
        attributes["conflict"] = attributes.fetch("conflict", {}).merge("progress_target_ids" => target_ids)
        attributes
      end

      def added_snapshot_blobs(changes)
        signed_ids = changes.flat_map do |change|
          History.extract_signed_ids(change.after["description"]) +
            History.extract_signed_ids(change.after["markdown_source"])
        end.uniq
        before_ids = changes.flat_map do |change|
          History.extract_signed_ids(change.before["description"]) +
            History.extract_signed_ids(change.before["markdown_source"])
        end.uniq

        (signed_ids - before_ids).filter_map do |signed_id|
          blob = ActiveStorage::Blob.find_signed(signed_id)
          next unless blob

          { old_signed_id: signed_id, attributes: blob.attributes.except("id", "created_at", "updated_at") }
        end
      end

      def persist(payload)
        replacements = restore_blob_rows(payload[:blobs])
        changes = virtualize_creations(payload.fetch(:changes))
        rewrite_snapshot_strings!(changes, replacements)

        CreativeChangeSet.transaction do
          draft = CreativeChangeSet.create!(payload.fetch(:change_set).merge(status: "draft", applied_at: nil))
          changes.each do |attributes|
            change = draft.creative_changes.create!(attributes)
            History.retain_snapshot_files!(change)
          end
          draft
        end
      end

      def restore_blob_rows(blobs)
        blobs.to_h do |blob_data|
          blob = ActiveStorage::Blob.create!(blob_data.fetch(:attributes))
          [ blob_data.fetch(:old_signed_id), blob.signed_id ]
        end
      end

      def virtualize_creations(changes)
        created_ids = changes.select { |change| change.fetch("before").empty? }
          .map { |change| change.fetch("creative_id") }
        id_map = created_ids.each_with_index.to_h { |id, index| [ id, -(index + 1) ] }

        changes.map do |attributes|
          attributes = attributes.deep_dup
          attributes["creative_id"] = id_map.fetch(attributes["creative_id"], attributes["creative_id"])
          if attributes["before"].empty?
            attributes["previous_parent_id"] ||= attributes.dig("after", "parent_id") || @anchor&.id
          end
          rewrite_parent_ids!(attributes, id_map)
          attributes
        end
      end

      def rewrite_parent_ids!(attributes, id_map)
        %w[before after].each do |side|
          parent_id = attributes.dig(side, "parent_id")
          attributes[side]["parent_id"] = id_map.fetch(parent_id, parent_id) if parent_id
        end
        previous_parent_id = attributes["previous_parent_id"]
        attributes["previous_parent_id"] = id_map.fetch(previous_parent_id, previous_parent_id) if previous_parent_id
        target_ids = attributes.dig("conflict", "progress_target_ids")
        attributes["conflict"]["progress_target_ids"] = target_ids.map { |id| id_map.fetch(id, id) } if target_ids
      end

      def rewrite_snapshot_strings!(changes, replacements)
        return if replacements.empty?

        changes.each do |attributes|
          %w[before after].each do |side|
            %w[description markdown_source].each do |key|
              next unless attributes[side].key?(key)

              value = attributes.dig(side, key)
              attributes[side][key] = replacements.reduce(value) { |text, (old_id, new_id)| text&.gsub(old_id, new_id) }
            end
          end
        end
      end

      def pending_result(draft)
        {
          success: true,
          status: "pending_review",
          pending_review: true,
          change_set_id: draft.id
        }
      end
    end
  end
end
