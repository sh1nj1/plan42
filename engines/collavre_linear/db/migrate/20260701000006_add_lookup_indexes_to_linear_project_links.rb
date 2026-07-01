# frozen_string_literal: true

# Inbound webhooks resolve the ProjectLink by team_id and by linear_project_id
# on every delivery. The pre-existing composite [creative_id, linear_project_id]
# index can't serve a team_id lookup and doesn't lead with linear_project_id, so
# both hot-path lookups full-scanned. Add covering single-column indexes.
class AddLookupIndexesToLinearProjectLinks < ActiveRecord::Migration[8.0]
  def change
    add_index :linear_project_links, :team_id
    # UNIQUE: one Linear project maps to exactly one Collavre root. Inbound
    # webhooks resolve the project via an unscoped find_by(linear_project_id:),
    # so a second link on a disjoint creative would route imports to whichever
    # row the DB returns. The controller's check-then-save can't stop two
    # concurrent link requests from both inserting; enforce it at the DB layer.
    add_index :linear_project_links, :linear_project_id, unique: true
  end
end
