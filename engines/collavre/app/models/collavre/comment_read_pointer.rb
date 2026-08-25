module Collavre
  class CommentReadPointer < ApplicationRecord
    self.table_name = "comment_read_pointers"

    belongs_to :user, class_name: Collavre.configuration.user_class_name
    belongs_to :creative, class_name: "Collavre::Creative"
    belongs_to :topic, class_name: "Collavre::Topic", optional: true
    belongs_to :last_read_comment, class_name: "Collavre::Comment", optional: true

    # A NULL topic is the legacy creative-wide watermark. It remains as a
    # fallback for topics created after the migration.
    validates :user_id, uniqueness: { scope: %i[creative_id topic_id] }

    # Mapping a pointer onto the comment its receipt avatar renders against lives
    # in Comments::ReadReceiptIndex, which resolves it in the same query that
    # loads the pointers and bounds the lookup to the rendered window. Do not
    # reintroduce a model-side variant: two implementations drift, and the
    # in-Ruby one required loading every public comment id on the creative.
  end
end
