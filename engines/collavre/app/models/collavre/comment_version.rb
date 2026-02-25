# frozen_string_literal: true

module Collavre
  class CommentVersion < ApplicationRecord
    self.table_name = "comment_versions"

    belongs_to :comment, class_name: "Collavre::Comment"
    belongs_to :review_comment, class_name: "Collavre::Comment", optional: true

    validates :content, presence: true
    validates :version_number, presence: true,
                               uniqueness: { scope: :comment_id },
                               numericality: { only_integer: true, greater_than: 0 }
  end
end
