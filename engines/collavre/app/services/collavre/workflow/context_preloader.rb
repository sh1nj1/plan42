# frozen_string_literal: true

module Collavre
  module Workflow
    # Keeps target inheritance reads independent of origin and ancestor depth.
    class ContextPreloader
      def self.preload(creative)
        preload_origins(creative) if creative.origin_id
        origin = creative.effective_origin(Set.new)
        preload_ancestors(origin) if origin.parent_id
        origin
      end

      def self.preload_origins(creative)
        # UNION stops cycles; only scalar columns participate in deduplication
        # so the query also works with PostgreSQL JSON metadata columns.
        origins = Creative.find_by_sql([ <<~SQL, { id: creative.id } ])
          WITH RECURSIVE workflow_origins (id, origin_id) AS (
            SELECT id, origin_id FROM "creatives" WHERE id = :id
            UNION
            SELECT "creatives".id, "creatives".origin_id
            FROM "creatives"
            INNER JOIN workflow_origins ON "creatives".id = workflow_origins.origin_id
          )
          SELECT "creatives".* FROM "creatives"
          INNER JOIN workflow_origins ON "creatives".id = workflow_origins.id
        SQL
        indexed = origins.index_by(&:id).merge(creative.id => creative)
        indexed.each_value do |record|
          record.association(:origin).target = indexed[record.origin_id] if record.origin_id
        end
      end

      def self.preload_ancestors(origin)
        indexed = origin.ancestors.index_by(&:id).merge(origin.id => origin)
        indexed.each_value do |record|
          # Retain lazy traversal for stale closure rows after a parent was
          # changed without callbacks, including legacy cyclic hierarchies.
          next if record.parent_id && !indexed.key?(record.parent_id)

          record.association(:parent).target = indexed[record.parent_id]
        end
      end

      private_class_method :preload_origins, :preload_ancestors
    end
  end
end
