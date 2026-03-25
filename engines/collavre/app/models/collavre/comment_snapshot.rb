# frozen_string_literal: true

module Collavre
  class CommentSnapshot < ApplicationRecord
    self.table_name = "comment_snapshots"

    belongs_to :creative, class_name: "Collavre::Creative"
    belongs_to :topic, class_name: "Collavre::Topic", optional: true
    belongs_to :user, class_name: Collavre.configuration.user_class_name
    belongs_to :result_comment, class_name: "Collavre::Comment", optional: true

    validates :operation, presence: true, inclusion: { in: %w[compress merge] }
    validates :comments_data, presence: true

    scope :restorable, -> { where(restored_at: nil) }
    scope :restored, -> { where.not(restored_at: nil) }

    def restorable?
      restored_at.nil?
    end

    def comment_count
      comments_data.size
    end
  end
end
