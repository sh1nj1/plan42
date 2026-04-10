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
                       "This tool requires approval before execution.\n\n" \
                       "Each operation is a hash with an 'action' key ('create', 'update', or 'delete') plus action-specific fields."

      def self.requires_approval?
        true
      end

      tool_param :operations, description: "Array of operation objects. Each object must have an 'action' key.\n\n" \
                 "For 'create': { action: 'create', parent_id: <int>, description: <string>, progress: <float>, after_id: <int>, before_id: <int> }\n" \
                 "For 'update': { action: 'update', id: <int>, description: <string>, progress: 1.0, parent_id: <int> } — progress only accepts 1.0 (complete) and only on leaf Creatives\n" \
                 "For 'delete': { action: 'delete', id: <int> }\n\n" \
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

      private

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

        Creatives::DestroyService.new(
          creative: creative,
          user: Current.user
        ).call
        { success: true, id: id, deleted: true }
      end
    end
  end
end
