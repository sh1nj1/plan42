# frozen_string_literal: true

# One Collavre root maps to exactly one Linear project. The controller's
# origin_conflict check is check-then-save, so two concurrent link requests for
# the SAME root to DIFFERENT projects can both pass it and insert — the existing
# unique indexes don't stop it: linear_project_id is unique per project (not per
# root) and the composite [creative_id, linear_project_id] permits two different
# projects on one creative. resolve_project_link then does find_by(creative_id:)
# and would sync against an arbitrary project. Enforce the invariant at the DB
# layer: promote the creative_id index to UNIQUE (which subsumes and replaces the
# now-redundant composite).
class EnforceOneProjectLinkPerCreative < ActiveRecord::Migration[8.0]
  def change
    remove_index :linear_project_links,
                 name: "index_linear_project_links_on_creative_and_project"
    remove_index :linear_project_links, :creative_id
    add_index :linear_project_links, :creative_id, unique: true
  end
end
