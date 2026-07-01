# frozen_string_literal: true

module CollavreLinear
  class ProjectLink < ApplicationRecord
    self.table_name = "linear_project_links"

    belongs_to :creative, class_name: "::Collavre::Creative"
    belongs_to :account, class_name: "CollavreLinear::Account"

    enum :sync_state, { synced: 0, dirty: 1, syncing: 2, conflict: 3 }, prefix: false

    validates :linear_project_id, presence: true
    validates :team_id, presence: true
    validates :webhook_secret, presence: true

    before_validation :ensure_webhook_secret
    before_save :ensure_webhook_secret

    scope :auto_syncable, -> { where(sync_state: %i[synced dirty]) }

    private

    def ensure_webhook_secret
      self.webhook_secret ||= SecureRandom.hex(20)
    end
  end
end
