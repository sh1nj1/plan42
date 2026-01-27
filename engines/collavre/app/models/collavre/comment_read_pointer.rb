module Collavre
  class CommentReadPointer < ApplicationRecord
    self.table_name = "comment_read_pointers"

    belongs_to :user, class_name: Collavre.configuration.user_class_name
    belongs_to :creative, class_name: "Collavre::Creative"
    belongs_to :last_read_comment, class_name: "Collavre::Comment", optional: true

    validates :user_id, uniqueness: { scope: :creative_id }

    def effective_comment_id(sorted_visible_ids)
      return nil unless last_read_comment_id

      # Find the nearest visible comment ID <= last_read_comment_id
      idx = sorted_visible_ids.bsearch_index { |x| x > last_read_comment_id }

      if idx
        # If idx is 0, target is smaller than all visible IDs
        idx > 0 ? sorted_visible_ids[idx - 1] : nil
      else
        # target is >= all visible IDs
        sorted_visible_ids.last
      end
    end
  end
end
