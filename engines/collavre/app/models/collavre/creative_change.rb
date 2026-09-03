# frozen_string_literal: true

module Collavre
  class CreativeChange < ApplicationRecord
    self.table_name = "creative_changes"

    OPERATIONS = %w[create update move reorder archive unarchive destroy].freeze

    belongs_to :change_set, class_name: "Collavre::CreativeChangeSet",
                            foreign_key: :creative_change_set_id,
                            inverse_of: :creative_changes
    belongs_to :creative, class_name: "Collavre::Creative"
    has_many :history_file_attachments,
             -> { where(name: "history_files") },
             as: :record,
             class_name: "ActiveStorage::Attachment",
             inverse_of: :record,
             dependent: :delete_all

    validates :operation, inclusion: { in: OPERATIONS }
    validates :creative_id, uniqueness: { scope: :creative_change_set_id }

    after_create_commit :ensure_history_topic

    private

    def ensure_history_topic
      return if change_set.origin == "sync"

      anchor = change_set.anchor_creative || Creative.unscoped.find_by(id: creative_id)
      return unless anchor

      anchor.history_topic(fallback_user: change_set.user || anchor.user)
    end
  end
end
