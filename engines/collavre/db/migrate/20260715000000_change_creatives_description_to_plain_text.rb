class ChangeCreativesDescriptionToPlainText < ActiveRecord::Migration[8.1]
  # The original AddDescriptionToCreatives migration created the column as
  # `:text, limit: 4294967295` (a MySQL LONGTEXT-style byte cap). SQLite ignores
  # the limit, but it gets recorded in db/schema.rb, and `db:schema:load` then
  # crashes on PostgreSQL (production) with:
  #   ArgumentError: No text type has byte size 4294967295.
  # Postgres `text` is already unbounded, so drop the limit to keep the schema
  # loadable on every adapter.
  def up
    change_column :creatives, :description, :text, limit: nil
  end

  def down
    change_column :creatives, :description, :text, limit: 4294967295
  end
end
