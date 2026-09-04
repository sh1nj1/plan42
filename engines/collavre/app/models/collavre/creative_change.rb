# frozen_string_literal: true

module Collavre
  class CreativeChange < ApplicationRecord
    self.table_name = "creative_changes"

    OPERATIONS = %w[create update move reorder archive unarchive destroy].freeze
    ARCHIVE_PROPAGATION_KEYS = %w[archived_at progress].freeze

    belongs_to :change_set, class_name: "Collavre::CreativeChangeSet",
                            foreign_key: :creative_change_set_id,
                            inverse_of: :creative_changes
    # Draft create operations use a negative temporary id until approval creates
    # the real row and remaps the change. Applied history still points at a live
    # Creative, while the optional association lets the draft diff exist first.
    belongs_to :creative, class_name: "Collavre::Creative", optional: true
    has_many :history_file_attachments,
             -> { where(name: "history_files") },
             as: :record,
             class_name: "ActiveStorage::Attachment",
             inverse_of: :record,
             dependent: :delete_all

    validates :operation, inclusion: { in: OPERATIONS }
    validates :creative_id, uniqueness: { scope: :creative_change_set_id }

    def archive_propagation_only?
      operation.in?(%w[archive unarchive]) && before["archived_at"] != after["archived_at"] &&
        before.except(*ARCHIVE_PROPAGATION_KEYS) == after.except(*ARCHIVE_PROPAGATION_KEYS)
    end

    def review_skipped?
      conflict["disposition"] == "skipped"
    end

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
