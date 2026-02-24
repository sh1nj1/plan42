module Mis2
  class ActivityLog < ApplicationRecord
    self.table_name = "mis_activity_log"

    # Whitelist of tables allowed in undo operations
    ALLOWED_TABLES = %w[
      map_assignment_user map_assignment_unit_user assignment_log
      assignment_survey survey_result learning_statistics learning_result
      brain_user
    ].freeze

    belongs_to :user, class_name: "Collavre::User"

    def undoable?
      metadata&.dig("undoable") == true && undone_at.nil?
    end

    def undo!(performed_by:)
      raise I18n.t("mis2.activity_logs.undo.not_undoable") unless undoable?

      operations = metadata["operations"]
      raise I18n.t("mis2.activity_logs.undo.no_operations") if operations.blank?

      db = metadata["database"]
      conn = resolve_connection(db)

      # Reverse: operations stored in leaf→root (delete order), undo needs root→leaf (insert order)
      reversed_ops = operations.reverse

      # Execute external DB restore and main DB logging in sequence.
      # If external DB succeeds but main DB fails, undo is not recorded — the external
      # data is restored but can be manually cleaned up via the activity log.
      conn.transaction do
        reversed_ops.each do |op|
          validate_table!(op["table"])

          case op["type"]
          when "delete"
            undo_delete(conn, op)
          when "update"
            undo_update(conn, op)
          else
            raise "Unknown operation type: #{op['type']}"
          end
        end
      end

      # Record the undo action itself (not undoable)
      undo_log = Mis2::ActivityLog.create!(
        user_id: performed_by.id,
        user_name: performed_by.name,
        action: "undo",
        target_type: target_type,
        target_id: target_id,
        message: I18n.t("mis2.activity_log.messages.undo",
          original_action: action,
          original_id: id
        ),
        metadata: {
          "undoable" => false,
          "original_log_id" => id,
          "original_action" => action
        }
      )

      # Mark this log as undone (undone_at DB column is the single source of truth)
      update!(
        undone_at: Time.current,
        metadata: metadata.merge(
          "undone_by" => performed_by.id,
          "undo_log_id" => undo_log.id
        )
      )
    end

    private

    def resolve_connection(db)
      case db
      when "h2"
        Mis2::H2Record.connection
      when "h3"
        Mis2::H3Record.connection
      else
        raise "Unknown database: #{db}"
      end
    end

    def validate_table!(table)
      return if ALLOWED_TABLES.include?(table)

      raise "Disallowed table in undo operation: #{table}"
    end

    def undo_delete(conn, op)
      table = op["table"]
      rows = op["rows"]
      return if rows.blank?

      rows.each do |row|
        columns = row.keys
        placeholders = columns.map { "?" }.join(", ")
        quoted_cols = columns.map { |c| conn.quote_column_name(c) }.join(", ")
        values = columns.map { |c| normalize_value(row[c]) }
        sql = "INSERT INTO #{conn.quote_table_name(table)} (#{quoted_cols}) VALUES (#{placeholders})"
        conn.execute(ActiveRecord::Base.sanitize_sql_array([ sql ] + values))
      end
    end

    # Convert ISO8601 datetime strings (from JSON) to MySQL-compatible format
    def normalize_value(val)
      return val unless val.is_a?(String)

      if val.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
        Time.parse(val).strftime("%Y-%m-%d %H:%M:%S")
      else
        val
      end
    rescue ArgumentError
      val
    end

    def undo_update(conn, op)
      table = op["table"]
      pk = op["primary_key"]
      pk_value = op["primary_key_value"]
      old_values = op["old_values"]

      set_clause = old_values.keys.map { |col| "#{conn.quote_column_name(col)} = ?" }.join(", ")
      sql = "UPDATE #{conn.quote_table_name(table)} SET #{set_clause} WHERE #{conn.quote_column_name(pk)} = ?"
      values = old_values.values + [ pk_value ]
      conn.execute(ActiveRecord::Base.sanitize_sql_array([ sql ] + values))
    end
  end
end
