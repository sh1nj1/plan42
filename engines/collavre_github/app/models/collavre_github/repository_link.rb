module CollavreGithub
  class RepositoryLink < ApplicationRecord
    self.table_name = "github_repository_links"

    belongs_to :creative, class_name: "Collavre::Creative"
    belongs_to :github_account, class_name: "CollavreGithub::Account"
    belongs_to :markdown_root_creative, class_name: "Collavre::Creative", optional: true

    # HMAC secret GitHub signs webhook deliveries with. Encrypted at rest so a
    # DB/backup leak can't forge webhooks (mirrors CollavreGithub::Account#token
    # and CollavreLinear::ProjectLink#webhook_secret). Non-deterministic: the
    # value is only ever read back decrypted (WebhooksController, provisioner),
    # never queried by ciphertext. A backfill migration re-encrypts pre-existing
    # plaintext rows.
    encrypts :webhook_secret, deterministic: false

    validates :repository_full_name, presence: true
    validates :webhook_secret, presence: true

    before_validation :ensure_webhook_secret

    scope :markdown_sync, -> { where(markdown_sync_enabled: true) }

    # Every link for one GitHub repository, matched by its stable id plus
    # unbackfilled name-only siblings.
    #
    # `repository_full_name` is the only key webhook routing used to have, and
    # it is not stable: renaming a repository on GitHub changes `full_name` in
    # every subsequent payload with no local event to notice it. The lookup
    # then found nothing, the controller fell through to a fallback secret that
    # production does not configure, and every delivery was answered 401 before
    # dispatch — silently, since the deliveries ledger is only written after
    # signature verification. `repository.id` does survive a rename, which is
    # why it is matched first-class here.
    #
    # When an id is present, name matching is restricted to NULL-id rows. A
    # repository linked to two creatives can be half-backfilled (one row
    # stamped, its sibling still nil), so those legacy siblings must remain in
    # the fan-out. Rows carrying another id are authoritative links to another
    # repository, even when GitHub has reused their stored name.
    def self.for_repository(id:, full_name:)
      name = full_name.to_s.downcase.presence
      if id.present?
        by_id = where(repository_id: id)
        return by_id unless name

        unbackfilled_by_name = where(repository_id: nil)
          .where("LOWER(repository_full_name) = ?", name)
        return by_id.or(unbackfilled_by_name)
      end

      name ? where("LOWER(repository_full_name) = ?", name) : none
    end

    # A parent link normally applies to every descendant, but a descendant may
    # carry its own link for another repository that reused the same name. An
    # explicit different id proves the conflict; a NULL id is unverified and
    # must fail closed. In either case, the descendant's channels must not be
    # renamed through the parent.
    def self.conflicting_repository_in_scope?(creative:, full_name:, repository_id:)
      return false if creative.blank? || full_name.blank? || repository_id.blank?

      creative_ids = [ creative.id ] + creative.ancestors.pluck(:id)
      where(creative_id: creative_ids)
        .where("LOWER(repository_full_name) = ?", full_name.to_s.downcase)
        .where("repository_id IS NULL OR repository_id <> ?", repository_id)
        .exists?
    end

    # Link mutations affect the link's whole descendant subtree, while an
    # ancestor link is inherited into the same scope. Before assigning a
    # canonical name, reject any NULL/different-id row in either direction so
    # case variants cannot leave both repositories permanently undispatchable.
    def self.identity_conflict_in_link_scope(creative:, full_name:, repository_id:, excluding_id: nil)
      return if creative.blank? || full_name.blank? || repository_id.blank?

      creative_ids = creative.subtree_ids + creative.ancestors.pluck(:id)
      candidates = where(creative_id: creative_ids)
        .where("LOWER(repository_full_name) = ?", full_name.to_s.downcase)
        .where("repository_id IS NULL OR repository_id <> ?", repository_id)
      candidates = candidates.where.not(id: excluding_id) if excluding_id
      candidates.order(:id).first
    end

    def markdown_sync_branch
      sync_branch.presence || "main"
    end

    private

    def ensure_webhook_secret
      self.webhook_secret ||= SecureRandom.hex(20)
    end
  end
end
