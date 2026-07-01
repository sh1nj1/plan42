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

    def initialize(creative)
      @creative = creative
    end

    def sync!
      project_link = resolve_project_link
      return unless project_link

      account = project_link.account
      client  = Client.new(account)
      attrs   = FieldMapper.creative_to_issue_attrs(adapt(@creative))
      hash    = compute_content_hash(attrs)

      issue_link = @creative.linear_issue_links.first

      if issue_link.nil?
        create_issue!(client, project_link, attrs, hash)
      else
        update_issue!(client, issue_link, attrs, hash)
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
      parent = @creative.parent
      return nil unless parent

      parent.linear_issue_links.first&.linear_issue_id
    end

    # SHA-256 of the sorted, serialised mapped attrs (stable key order).
    def compute_content_hash(attrs)
      Digest::SHA256.hexdigest(attrs.sort.to_h.to_json)
    end

    def create_issue!(client, project_link, attrs, hash)
      parent_id  = parent_linear_issue_id
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

    def update_issue!(client, issue_link, attrs, hash)
      issue_link.with_lock do
        # Re-check under lock: a concurrent update with identical content must not
        # trigger a redundant API call.  The pre-lock check is gone intentionally
        # to eliminate the TOCTOU window between the dirty-check and the lock
        # acquisition.
        return issue_link if issue_link.content_hash == hash

        response = client.update_issue(issue_link.linear_issue_id, **attrs)

        issue_link.update!(
          content_hash:      hash,
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
