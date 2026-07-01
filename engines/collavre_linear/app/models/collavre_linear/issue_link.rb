# frozen_string_literal: true

module CollavreLinear
  class IssueLink < ApplicationRecord
    self.table_name = "linear_issue_links"

    belongs_to :creative, class_name: "::Collavre::Creative"
    belongs_to :project_link, class_name: "CollavreLinear::ProjectLink"

    # linear_comment_links.issue_link_id has an FK to this row; cascade so the
    # ProjectLink -> IssueLink -> CommentLink chain cleans up fully on unlink.
    has_many :comment_links, class_name: "CollavreLinear::CommentLink", dependent: :destroy

    enum :sync_state, { synced: 0, dirty: 1, syncing: 2, conflict: 3 }, prefix: false

    validates :linear_issue_id, presence: true, uniqueness: true
    validates :creative_id, uniqueness: true
    validates :project_link, presence: true
  end
end
