module Collavre
  require "sorbet-runtime"
  require "rails_mcp_engine"

  module Tools
    class CreativeBatchService
      extend T::Sig
      extend ToolMeta

      tool_name "creative_batch_service"
      tool_description "Execute multiple Creative operations (create, update, delete) in a single batch call. " \
                       "All operations run inside a transaction — if any operation fails, the entire batch is rolled back.\n\n" \
                       "Delete operations archive Creatives so they remain recoverable from History.\n\n" \
                       "A Creative with inherited ai_write_policy=review stores a draft in History for approval instead of applying immediately.\n\n" \
                       "Each operation is a hash with an 'action' key ('create', 'update', or 'delete') plus action-specific fields."

      def self.requires_approval?
        false
      end

      tool_param :operations, description: "Array of operation objects. Each object must have an 'action' key.\n\n" \
                 "For 'create': { action: 'create', parent_id: <int>, description: <markdown string>, progress: <float>, after_id: <int>, before_id: <int> }\n" \
                 "For 'update': { action: 'update', id: <int>, description: <markdown string>, progress: 1.0, parent_id: <int> } — progress only accepts 1.0 (complete) and only on leaf Creatives\n" \
                 "For 'delete': { action: 'delete', id: <int> } — archives the Creative and its propagated family\n\n" \
                 "The 'description' field is written as Markdown (GitHub-Flavored).\n" \
                 "Fields other than 'action' and 'id'/'parent_id' are optional.", required: true

      class BatchRollbackError < StandardError
        attr_reader :results

        def initialize(results)
          @results = results
          super("Batch operation failed")
        end
      end

      sig { params(operations: T::Array[T::Hash[String, T.untyped]]).returns(T::Hash[Symbol, T.untyped]) }
      def call(operations:)
        raise "Current.user is required" unless Current.user

        Creatives::AiWritePolicy.capture(
          creatives: review_targets(operations),
          anchor: Creatives::AiWritePolicy.agent_anchor
        ) { perform_operations(operations) }
      end

      private

      def perform_operations(operations)
        results = []

        ApplicationRecord.transaction do
          operations.each_with_index do |op, idx|
            op = op.transform_keys(&:to_s)
            action = op["action"]

            result = case action
            when "create" then execute_create(op)
            when "update" then execute_update(op)
            when "delete" then execute_delete(op)
            else
                       { error: "Unknown action '#{action}'" }
            end

            result[:index] = idx
            result[:action] = action
            results << result

            raise BatchRollbackError, results if result[:error]
          end
        end

        { success: true, results: results }
      rescue BatchRollbackError => e
        failed = e.results.find { |r| r[:error] }
        { success: false, error: "Operation #{failed[:index]} (#{failed[:action]}) failed: #{failed[:error]}", results: e.results }
      end

      def review_targets(operations)
        ids = operations.flat_map do |operation|
          operation = operation.stringify_keys
          [ operation["id"], operation["parent_id"], operation["before_id"], operation["after_id"] ]
        end.compact.map(&:to_i).select(&:positive?)
        creatives = Creative.where(id: ids).to_a
        delete_ids = operations.filter_map do |operation|
          operation = operation.stringify_keys
          operation["id"].to_i if operation["action"] == "delete"
        end.to_set
        archive_targets = creatives.select { |creative| delete_ids.include?(creative.id) }
          .flat_map { |creative| creative.archive_family.to_a }
        archive_targets.concat(moved_families_before_delete(operations, creatives))
        progress_targets = propagation_targets(progress_sources(operations, creatives))
        archive_progress_targets = propagation_targets(archive_targets)
        structural_progress_sources = structural_progress_sources(operations, creatives)
        structural_progress_targets = propagation_targets(structural_progress_sources)
        [
          *creatives, *archive_targets, *progress_targets, *archive_progress_targets,
          *structural_progress_sources, *structural_progress_targets, *reorder_targets(operations)
        ]
      end

      def progress_sources(operations, creatives)
        progress_ids = operations.filter_map do |operation|
          operation = operation.stringify_keys
          operation["id"].to_i if operation["action"] == "update" && operation["progress"].present?
        end.to_set
        creatives.select { |creative| progress_ids.include?(creative.id) }
      end

      def propagation_targets(creatives)
        creatives.flat_map { |creative| Creatives::ProgressPropagationTargets.new(creative.effective_origin).call }
      end

      def structural_progress_sources(operations, creatives)
        records = creatives.index_by(&:id)
        operations.flat_map do |operation|
          operation = operation.stringify_keys
          case operation["action"]
          when "create"
            records[operation["parent_id"].to_i]
          when "update"
            move_progress_sources(operation, records)
          end
        end.compact
      end

      def move_progress_sources(operation, records)
        return [] unless operation["parent_id"].present? && operation["parent_id"].to_i.positive?

        [ records[operation["id"].to_i]&.parent, records[operation["parent_id"].to_i] ].compact
      end

      def moved_families_before_delete(operations, creatives)
        records = creatives.index_by(&:id)
        delete_indexes = operations.each_index.select { |index| operations[index].stringify_keys["action"] == "delete" }
        operations.each_with_index.flat_map do |operation, index|
          operation = operation.stringify_keys
          next [] unless operation["action"] == "update" && delete_indexes.any? { |delete_index| delete_index > index }
          next [] unless operation["parent_id"].present? && operation["parent_id"].to_i.positive?

          records[operation["id"].to_i]&.archive_family&.to_a || []
        end
      end

      def reorder_targets(operations)
        operations.flat_map do |operation|
          operation = operation.stringify_keys
          next [] unless operation["action"] == "create" && (operation["before_id"].present? || operation["after_id"].present?)

          parent_id = operation["parent_id"].to_i
          parent_id.positive? ? Creative.where(parent_id: parent_id).to_a : Creative.roots.to_a
        end
      end

      def execute_create(op)
        service = CreativeCreateService.new
        service.call(
          description: op["description"] || "",
          parent_id: op["parent_id"]&.to_i,
          progress: op["progress"]&.to_f,
          after_id: op["after_id"]&.to_i,
          before_id: op["before_id"]&.to_i
        )
      end

      def execute_update(op)
        id = op["id"]&.to_i
        return { error: "id is required for update" } unless id&.positive?

        service = CreativeUpdateService.new
        service.call(
          id: id,
          description: op["description"],
          progress: op.key?("progress") ? op["progress"]&.to_f : nil,
          parent_id: op.key?("parent_id") ? op["parent_id"]&.to_i : nil
        )
      end

      def execute_delete(op)
        id = op["id"]&.to_i
        return { error: "id is required for delete" } unless id&.positive?

        creative = Creative.find_by(id: id)
        return { error: "Creative not found", id: id } unless creative
        return { error: "No write permission on this Creative", id: id } unless creative.has_permission?(Current.user, :write)

        creative.archive!
        { success: true, id: id, archived: true }
      end
    end
  end
end
