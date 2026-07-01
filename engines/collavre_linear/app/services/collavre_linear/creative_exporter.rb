# frozen_string_literal: true

require "digest"

module CollavreLinear
  # Syncs a single Collavre::Creative to Linear as an issue.
  #
  # Usage:
  #   CollavreLinear::CreativeExporter.new(creative).sync!
  #
  # Resolves the governing ProjectLink from the creative itself or its nearest
  # ancestor. Creates a new Linear issue and IssueLink on first run; updates the
  # existing issue on subsequent runs.  Skips the network call when the content
  # hash is unchanged (dirty-tracking).  Raises Client::Error on network failure
  # so the caller (OutboundSyncJob) can retry.
  class CreativeExporter
    # Thin adapter so FieldMapper's #title contract is met without touching core.
    # Collavre::Creative has no :title column — we derive it from creative_snippet
    # (plain-text truncation of the description used everywhere in the app).
    CreativeAdapter = Struct.new(:title, :description, :sequence, :data, keyword_init: true)

    # Compute the outbound content hash for a Creative's current state. Shared
    # with the inbound applier so it can advance IssueLink#content_hash after
    # applying a remote update, keeping the exporter's dirty-check consistent.
    #
    # The hash folds in the parent's linear_issue_id so that a pure reparent
    # (content fields unchanged) still changes the hash and drives update_issue!,
    # which pushes the new parentId to Linear. Otherwise Collavre and Linear
    # hierarchies would diverge after a move.
    def self.content_hash_for(creative)
      attrs = FieldMapper.creative_to_issue_attrs(
        CreativeAdapter.new(
          title:       creative.creative_snippet,
          description: creative.description,
          sequence:    creative.sequence,
          data:        creative.data
        )
      )
      hash_attrs(attrs, parent_linear_issue_id_for(creative))
    end

    # Resolve the parent Creative's linked linear_issue_id (or nil when the
    # parent is absent or not itself linked to a Linear issue).
    def self.parent_linear_issue_id_for(creative)
      parent = creative.parent
      return nil unless parent

      parent.linear_issue_links.first&.linear_issue_id
    end

    # SHA-256 of the sorted, serialised mapped attrs plus the parent's linear
    # issue id (stable key order). Single source of truth so inbound + outbound
    # and the class/instance paths all agree.
    def self.hash_attrs(attrs, parent_linear_issue_id)
      payload = attrs.merge(_parent_linear_issue_id: parent_linear_issue_id)
      Digest::SHA256.hexdigest(payload.sort.to_h.to_json)
    end

    def initialize(creative)
      @creative = creative
    end

    def sync!
      project_link = resolve_project_link
      return unless project_link

      account   = project_link.account
      client    = Client.new(account)
      attrs     = FieldMapper.creative_to_issue_attrs(adapt(@creative))
      parent_id = parent_linear_issue_id
      hash      = compute_content_hash(attrs, parent_id)

      issue_link = @creative.linear_issue_links.first

      if issue_link.nil?
        create_issue!(client, project_link, attrs, hash, parent_id)
      else
        update_issue!(client, issue_link, attrs, hash, parent_id)
      end
    end

    private

    # Wrap a Collavre::Creative in the adapter expected by FieldMapper.
    # :title is derived from creative_snippet (plain-text, max 24 chars).
    def adapt(creative)
      CreativeAdapter.new(
        title:       creative.creative_snippet,
        description: creative.description,
        sequence:    creative.sequence,
        data:        creative.data
      )
    end

    # Walk self-and-ancestors (nearest first) to find a ProjectLink.
    # closure_tree's `self_and_ancestors` returns [self, parent, grandparent, …].
    def resolve_project_link
      @creative.self_and_ancestors.each do |ancestor|
        link = CollavreLinear::ProjectLink.find_by(creative_id: ancestor.id)
        return link if link
      end
      nil
    end

    # Find the parent Creative's linear_issue_id, if any.
    def parent_linear_issue_id
      self.class.parent_linear_issue_id_for(@creative)
    end

    # SHA-256 of the sorted, serialised mapped attrs plus the parent's linear
    # issue id (stable key order). Shared with CreativeExporter.content_hash_for
    # so inbound + outbound agree, including on reparents.
    def compute_content_hash(attrs, parent_id)
      self.class.hash_attrs(attrs, parent_id)
    end

    def create_issue!(client, project_link, attrs, hash, parent_id)
      response   = client.create_issue(
        team_id:    project_link.team_id,
        project_id: project_link.linear_project_id,
        parent_id:  parent_id,
        **attrs
      )

      linear_issue_id = response[:id]

      issue_link = CollavreLinear::IssueLink.create!(
        creative:        @creative,
        project_link:    project_link,
        linear_issue_id: linear_issue_id,
        parent_issue_id: parent_id,
        content_hash:    hash,
        remote_updated_at: Time.current,
        local_version:   1,
        sync_state:      :synced
      )

      EchoGuard.record_outbound(issue_link, linear_issue_id)
      issue_link
    end

    def update_issue!(client, issue_link, attrs, hash, parent_id)
      issue_link.with_lock do
        # Re-check under lock: a concurrent update with identical content must not
        # trigger a redundant API call.  The pre-lock check is gone intentionally
        # to eliminate the TOCTOU window between the dirty-check and the lock
        # acquisition.
        if issue_link.content_hash == hash
          # Content is already in sync with Linear.  If the observer marked the
          # link :dirty (e.g. for a metadata-only save that touched no mapped
          # field), reset it now so a subsequent inbound update does not
          # incorrectly trip conflict?.  Use update_column to avoid callbacks.
          if issue_link.dirty?
            issue_link.update_column(:sync_state, CollavreLinear::IssueLink.sync_states[:synced])
          end
          return issue_link
        end

        # Carry parentId on update so a reparent in Collavre moves the issue in
        # Linear too. Only send it when the parent is itself a linked Linear
        # issue (mirrors create_issue!); sending a nil/bogus parentId would error.
        update_fields = attrs
        update_fields = update_fields.merge(parent_id: parent_id) if parent_id

        response = client.update_issue(issue_link.linear_issue_id, **update_fields)

        issue_link.update!(
          content_hash:      hash,
          parent_issue_id:   parent_id,
          remote_updated_at: Time.current,
          local_version:     issue_link.local_version + 1,
          sync_state:        :synced
        )

        EchoGuard.record_outbound(issue_link, response[:id])
      end

      issue_link
    end
  end
end
