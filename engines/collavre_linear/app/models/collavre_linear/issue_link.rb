# frozen_string_literal: true

module CollavreLinear
  class IssueLink < ApplicationRecord
    self.table_name = "linear_issue_links"

    belongs_to :creative, class_name: "::Collavre::Creative"
    belongs_to :project_link, class_name: "CollavreLinear::ProjectLink"

    enum :sync_state, { synced: 0, dirty: 1, syncing: 2, conflict: 3 }, prefix: false

    validates :linear_issue_id, presence: true, uniqueness: true
    validates :creative_id, uniqueness: true
    validates :project_link, presence: true
  end
end
