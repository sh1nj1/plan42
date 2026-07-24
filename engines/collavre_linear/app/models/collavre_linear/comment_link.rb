# frozen_string_literal: true

module CollavreLinear
  class CommentLink < ApplicationRecord
    self.table_name = "linear_comment_links"

    belongs_to :issue_link, class_name: "CollavreLinear::IssueLink"

    validates :comment_id, presence: true
    validates :linear_comment_id, presence: true, uniqueness: true
  end
end
