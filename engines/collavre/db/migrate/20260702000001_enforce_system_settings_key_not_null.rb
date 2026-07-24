class EnforceSystemSettingsKeyNotNull < ActiveRecord::Migration[8.1]
  # `key` is the lookup identifier for every setting and the model already
  # validates its presence; the unique index exists but the column was left
  # nullable, allowing a NULL-keyed row to slip in outside the model. Enforce
  # the invariant at the database level to match the existing UNIQUE index.
  def change
    change_column_null :system_settings, :key, false
  end
end
