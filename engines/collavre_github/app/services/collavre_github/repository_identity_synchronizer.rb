module CollavreGithub
  # Persists a repository identity established through trusted evidence and
  # keeps attached channel routing keys in sync with the canonical GitHub name.
  #
  # Stable repository ids are authoritative. A NULL-id anchor is accepted only
  # by the explicit operator reattachment workflow; hook registrations and HMAC
  # secrets are not row identity because older provisioners propagated both.
  class RepositoryIdentitySynchronizer
    def self.call(
      anchor:,
      repository_id:,
      full_name:,
      trusted_secret: nil,
      allow_anchor_backfill: false
    )
      new(
        anchor: anchor,
        repository_id: repository_id,
        full_name: full_name,
        trusted_secret: trusted_secret,
        allow_anchor_backfill: allow_anchor_backfill
      ).call
    end

    def initialize(
      anchor:,
      repository_id:,
      full_name:,
      trusted_secret:,
      allow_anchor_backfill:
    )
      @anchor = anchor
      @repository_id = repository_id
      @full_name = full_name.to_s
      @trusted_secret = trusted_secret
      @allow_anchor_backfill = allow_anchor_backfill
    end

    def call
      return [] if anchor.blank? || repository_id.blank? || full_name.blank?

      synchronized = []
      old_names_by_creative = Hash.new { |hash, key| hash[key] = [] }

      RepositoryLink.transaction do
        candidate_links.each do |link|
          old_name = link.repository_full_name
          survivor = synchronize_link(link)
          next unless survivor

          synchronized << survivor
          if old_name.to_s == full_name
            next
          end

          old_names_by_creative[old_name.to_s.downcase] << survivor.creative_id
        end

        old_names_by_creative.each do |old_name, creative_ids|
          rename_channels(old_name, creative_ids.uniq)
        end
      end

      synchronized.uniq(&:id)
    end

    private

    attr_reader :anchor,
      :repository_id,
      :full_name,
      :trusted_secret,
      :allow_anchor_backfill

    def candidate_links
      links = RepositoryLink.where(repository_id: repository_id).to_a
      links << anchor if allow_anchor_backfill || anchor.repository_id.to_s == repository_id.to_s
      links.uniq(&:id)
    end

    def synchronize_link(link)
      if link.repository_full_name.to_s == full_name &&
          link.repository_id.to_s == repository_id.to_s
        return link
      end

      survivor = RepositoryLink
        .where(creative_id: link.creative_id)
        .where("LOWER(repository_full_name) = ?", full_name.downcase)
        .where.not(id: link.id)
        .first

      if survivor
        return unless survivor.repository_id.to_s == repository_id.to_s

        merge_links!(obsolete: link, survivor: survivor)
        return survivor
      end

      link.update_columns(repository_id: repository_id, repository_full_name: full_name)
      link
    end

    def merge_links!(obsolete:, survivor:)
      survivor.update!(
        webhook_secret: trusted_secret.presence || survivor.webhook_secret,
        webhook_hook_id: survivor.webhook_hook_id || obsolete.webhook_hook_id,
        markdown_sync_enabled: survivor.markdown_sync_enabled? || obsolete.markdown_sync_enabled?,
        markdown_root_creative_id: survivor.markdown_root_creative_id || obsolete.markdown_root_creative_id,
        sync_branch: survivor.sync_branch.presence || obsolete.sync_branch,
        last_synced_at: [ survivor.last_synced_at, obsolete.last_synced_at ].compact.max
      )
      obsolete.destroy!
    end

    def rename_channels(old_name, creative_ids)
      GithubPrChannel.where("LOWER(repo_full_name) = ?", old_name).find_each do |channel|
        creative = channel.topic&.creative
        next unless creative

        candidate_ids = [ creative.id ] + creative.ancestors.pluck(:id)
        next if (creative_ids & candidate_ids).empty?
        next if RepositoryLink.conflicting_repository_in_scope?(
          creative: creative,
          full_name: old_name,
          repository_id: repository_id
        )

        channel.synchronize_repository_name!(full_name)
      end
    end
  end
end
