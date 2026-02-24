module Mis2
  module H2
    class AssignmentUser < Mis2::H2Record
      self.table_name = "map_assignment_user"
      self.primary_key = "assignment_user_idx"

      belongs_to :user, class_name: "Mis2::H2::User", foreign_key: "user"
      belongs_to :assignment_record, class_name: "Mis2::H2::Assignment", foreign_key: "assignment"

      delegate :assignment_name, to: :assignment_record, allow_nil: true

      # Returns progress status based on start/end dates
      # - :scheduled if start_date > today
      # - :completed if end_date < today
      # - :in_progress otherwise
      def progress_status
        today = Date.current
        start_date = assignment_user_start&.to_date
        end_date = assignment_user_end&.to_date

        if start_date && start_date > today
          :scheduled
        elsif end_date && end_date < today
          :completed
        else
          :in_progress
        end
      end

      # Scope for listing with dates
      scope :for_user_with_details, ->(user_idx) {
        select("map_assignment_user.*, brain_assignment.assignment_name")
          .joins(:assignment_record)
          .where(user: user_idx)
          .order(Arel.sql("map_assignment_user.round DESC, map_assignment_user.create_time DESC"))
      }

      # Validation query
      def self.check_overlap(user_idx, target_assignment_idx, new_start, new_end)
        query = <<~SQL
          EXISTS(
              SELECT 1
              FROM map_assignment_user MAU
              WHERE MAU.user = ?
                AND MAU.assignment_user_idx != ?
                AND (
                  (? BETWEEN MAU.assignment_user_start AND MAU.assignment_user_end)
                  OR (? BETWEEN MAU.assignment_user_start AND MAU.assignment_user_end)
                  OR (MAU.assignment_user_start >= ? AND MAU.assignment_user_end <= ?)
                )
          )
        SQL
        connection.select_value(sanitize_sql_array([ query, user_idx, target_assignment_idx, new_start, new_end, new_start, new_end ]))
      end

      # Backup all rows across 7 tables, then delete them in FK reverse order.
      # Returns an operations array for ActivityLog metadata (undo support).
      def self.backup_and_delete_round(round_idx, user_idx)
        operations = []

        transaction do
          # Subqueries used to find child rows (all parameterized via sanitize_sql_array)
          unit_user_sub = sanitize_sql_array([ "SELECT assignment_unit_user_idx FROM map_assignment_unit_user WHERE assignment_user = ?", round_idx ])
          stats_sub     = "SELECT idx FROM learning_statistics WHERE map_assignment_unit_user_idx IN (#{unit_user_sub})"
          survey_sub    = "SELECT id FROM assignment_survey WHERE map_assignment_unit_user_id IN (#{unit_user_sub})"

          # Leaf → root order: backup then delete each table
          cascade_tables = [
            { table: "learning_result",           pk: "idx",                       where: "learning_statistics_idx IN (#{stats_sub})" },
            { table: "learning_statistics",       pk: "idx",                       where: "map_assignment_unit_user_idx IN (#{unit_user_sub})" },
            { table: "survey_result",             pk: "idx",                       where: "assignment_survey_id IN (#{survey_sub})" },
            { table: "assignment_survey",         pk: "id",                        where: "map_assignment_unit_user_id IN (#{unit_user_sub})" },
            { table: "assignment_log",            pk: "idx",                       where: sanitize_sql_array([ "assignment_user = ?", round_idx ]) },
            { table: "map_assignment_unit_user",  pk: "assignment_unit_user_idx",  where: sanitize_sql_array([ "assignment_user = ?", round_idx ]) },
            { table: "map_assignment_user",       pk: "assignment_user_idx",       where: sanitize_sql_array([ "assignment_user_idx = ? AND user = ?", round_idx, user_idx ]) }
          ]

          cascade_tables.each do |entry|
            rows = connection.select_all("SELECT * FROM #{entry[:table]} WHERE #{entry[:where]}").to_a
            operations << { "type" => "delete", "table" => entry[:table], "primary_key" => entry[:pk], "rows" => rows }
            connection.execute("DELETE FROM #{entry[:table]} WHERE #{entry[:where]}")
          end
        end

        operations
      end

      # Update with safety check
      def self.safe_update_dates(user_idx, target_assignment_idx, new_start, new_end)
        # Using custom SQL update to strictly follow the requirement including the safety subquery
        sql = <<~SQL
          UPDATE map_assignment_user
          SET assignment_user_start = ?,
              assignment_user_end = ?
          WHERE assignment_user_idx = ?
            AND user = ?
            AND NOT EXISTS (
              SELECT 1
              FROM (SELECT * FROM map_assignment_user) AS CHECK_TABLE
              WHERE user = ?
                AND assignment_user_idx != ?
                AND (
                  (? BETWEEN assignment_user_start AND assignment_user_end)
                  OR (? BETWEEN assignment_user_start AND assignment_user_end)
                  OR (assignment_user_start >= ? AND assignment_user_end <= ?)
                )
          )
        SQL

        args = [
          new_start, new_end,
          target_assignment_idx, user_idx,
          user_idx, target_assignment_idx,
          new_start, new_end, new_start, new_end
        ]

        connection.update(sanitize_sql_array([ sql ] + args))
      end
    end
  end
end
