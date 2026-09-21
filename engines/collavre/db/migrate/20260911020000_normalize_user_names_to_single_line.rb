# frozen_string_literal: true

class NormalizeUserNamesToSingleLine < ActiveRecord::Migration[8.0]
  # Deliberately not Collavre::User: a data migration has to keep working after
  # the model moves on, and loading the real model here would run its callbacks
  # and validations against a schema from the future.
  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"
  end

  # Matches Collavre::User's name normalization. Mention parsing stops a name at
  # a line break, so a stored line break leaves that user's own canonical
  # mention "@name:" unresolvable and the mention falls through to ambient
  # routing. The normalization keeps new names to a single line; this brings
  # rows written before it in line.
  LINE_BREAK_RUN = /[^\S\r\n]*[\r\n]+[^\S\r\n]*/

  def up
    MigrationUser.where("name LIKE ? OR name LIKE ?", "%\n%", "%\r%").find_each do |user|
      normalized = user.name.to_s.gsub(LINE_BREAK_RUN, " ").strip
      next if normalized == user.name || normalized.blank?

      MigrationUser.where(id: user.id).update_all(name: normalized)
    end
  end

  def down
    # Irreversible: the original line breaks are not recoverable, and the names
    # are valid either way.
    raise ActiveRecord::IrreversibleMigration
  end
end
