# frozen_string_literal: true

module Collavre
  # Keeps denormalized real columns in lockstep with keys stored inside a JSON
  # column, so database indexes can be defined over plain columns instead of
  # JSON expressions.
  #
  # WHY: A JSON-expression index serializes per-adapter --
  # `json_extract(config, '$.x')` on SQLite vs `config->>'x'` on PostgreSQL.
  # Because schema.rb is dumped from the SQLite dev DB, it carries the
  # `json_extract` form, which is not a PostgreSQL function, so
  # `db:schema:load` crashes on the prod PostgreSQL database. Promote the JSON
  # key to a real column (which indexes and dumps identically on both adapters)
  # and keep it synced from the JSON column on every save. The JSON column
  # stays the source of truth; the promoted columns are re-derived on each save.
  #
  # Usage:
  #   include Collavre::IndexedJsonColumns
  #
  #   indexed_json_columns json: :config, columns: {
  #     repo_full_name: "repo_full_name",
  #     pr_number:      "pr_number",
  #   }
  #
  # `json:` names the JSON attribute (source of truth). `columns:` maps each
  # promoted column to the JSON key it mirrors. A before_save re-derives every
  # promoted column from the JSON attribute so the plain-column indexes enforce
  # the same guarantees the JSON-expression indexes did.
  module IndexedJsonColumns
    extend ActiveSupport::Concern

    included do
      class_attribute :indexed_json_source, instance_writer: false, default: nil
      class_attribute :indexed_json_column_map, instance_writer: false, default: {}.freeze
    end

    class_methods do
      def indexed_json_columns(json:, columns:)
        self.indexed_json_source = json.to_sym
        self.indexed_json_column_map =
          columns.each_with_object({}) { |(col, key), m| m[col.to_s] = key.to_s }.freeze
        before_save :sync_indexed_json_columns
      end
    end

    private

    # Re-derive each promoted column from its JSON key. Reads the JSON attribute
    # (source of truth) and writes through `[]=` so subtype reader overrides are
    # bypassed and only genuinely changed values dirty the record.
    def sync_indexed_json_columns
      json = public_send(indexed_json_source) || {}
      indexed_json_column_map.each do |column, json_key|
        # A promoted column may not exist yet when a record is saved during a
        # migration that runs before the add-column migration -- a full replay
        # reaches older record-saving migrations (e.g. 20251230113607_refactor_labels
        # calls Creative.create!) first. The JSON attribute stays the source of
        # truth, so skip the promoted column until it exists rather than aborting
        # the save with MissingAttributeError; the next save re-derives it.
        next unless has_attribute?(column)

        self[column] = json[json_key]
      end
    end
  end
end
