# frozen_string_literal: true

module CollavreLinear
  # Receives inbound webhooks from Linear.
  #
  # Security pipeline (all BEFORE enqueueing any work):
  #   1. Verify `Linear-Signature` = HMAC-SHA256(webhook_secret, raw_body) with
  #      a constant-time compare. Bad/missing signature -> 401.
  #   2. Verify `webhookTimestamp` (ms epoch) is within +/- 60s of now to reject
  #      replayed/stale deliveries. Out-of-window -> 401.
  #   3. Drop our own events (EchoGuard) to avoid sync loops. Echo -> 200 ack,
  #      but nothing enqueued.
  #
  # Machine-to-machine endpoint authenticated by the HMAC signature below, not a
  # user session. Inherits ActionController::API, which carries no CSRF
  # middleware — so there is nothing to skip, and no session cookie to forge.
  class WebhooksController < ActionController::API
    TIMESTAMP_WINDOW_MS = 60_000

    def create
      raw_body = request.raw_post.presence || request.body.read
      payload  = JSON.parse(raw_body)

      link    = find_project_link(payload)
      # Resolve the secret at the TEAM level, not off the matched row's own
      # column. find_project_link can return a specific row (project/issue/comment
      # branches) that committed blank in the paste race even though a sibling
      # holds the team's secret — verifying against the team's non-blank secret
      # keeps those deliveries from a spurious 401.
      secret  = link && CollavreLinear::ProjectLink.team_webhook_secret(link.team_id)

      return head :unauthorized unless valid_signature?(raw_body, secret)
      return head :unauthorized unless fresh_timestamp?(payload)
      # Signature only proves the sender holds the signing link's per-TEAM secret.
      # InboundApplier routes by the payload's own id/projectId, so a payload
      # signed with team A's secret but naming team B's project/issue would let a
      # user who can see A's (UI-visible) secret forge writes into B. Require every
      # other identifier to resolve to the SAME team before enqueueing.
      return head :unauthorized unless payload_identifiers_consistent?(payload, link)

      account = resolve_account(link)
      if account && CollavreLinear::EchoGuard.our_event?(account, payload)
        # Our own actor bounced back — ack so Linear stops retrying, but do not
        # re-apply our own change.
        return head :ok
      end

      CollavreLinear::InboundApplyJob.perform_later(payload)
      head :ok
    rescue JSON::ParserError
      head :bad_request
    end

    private

    # Match the payload's team/project to a ProjectLink so we can use its
    # per-link webhook secret and account. Returns nil when nothing matches —
    # the secret then resolves to nil and the delivery is rejected (401). There
    # is no ENV/admin fallback: the secret lives only on the ProjectLink.
    def find_project_link(payload)
      team_id = extract_team_id(payload)
      project_id = extract_project_id(payload)

      if team_id.present?
        # A team shares one webhook secret, but a sibling created concurrently
        # with the admin's paste can commit blank and would 401 the delivery if
        # the verifier picked it. Prefer any sibling that already holds the pasted
        # secret; fall back to any team row so routing still resolves before a
        # secret is ever pasted (that case 401s on the nil secret, as intended).
        siblings = CollavreLinear::ProjectLink.where(team_id: team_id).to_a
        link = siblings.find { |s| s.webhook_secret.present? } || siblings.first
        return link if link
      end

      if project_id.present?
        link = CollavreLinear::ProjectLink.find_by(linear_project_id: project_id)
        return link if link
      end

      # Comment deliveries carry no team/project fields — they reference the
      # parent issue instead. Resolve via the linked issue so verification uses
      # that project's per-link secret; without this the delivery matches no
      # link and is rejected (401).
      if (issue_id = extract_issue_id(payload)).present?
        issue_link = CollavreLinear::IssueLink.find_by(linear_issue_id: issue_id)
        return issue_link.project_link if issue_link
      end

      nil
    end

    # The webhook secret is shared per TEAM (siblings adopt it, rotation rolls the
    # whole team), so the team is the trust boundary. Every identifier the payload
    # carries that resolves to a ProjectLink must belong to the signing link's
    # team; a mismatch means a cross-team forgery signed with the wrong secret.
    def payload_identifiers_consistent?(payload, link)
      return false unless link

      project_id = extract_project_id(payload)
      if project_id.present?
        other = CollavreLinear::ProjectLink.find_by(linear_project_id: project_id)
        return false if other && other.team_id != link.team_id
      end

      issue_ids_in_payload(payload).each do |issue_id|
        issue_link = CollavreLinear::IssueLink.find_by(linear_issue_id: issue_id)
        return false if issue_link && issue_link.project_link.team_id != link.team_id
      end

      comment_ids_in_payload(payload).each do |comment_id|
        comment_link = CollavreLinear::CommentLink.find_by(linear_comment_id: comment_id)
        return false if comment_link &&
          comment_link.issue_link.project_link.team_id != link.team_id
      end

      true
    end

    # Every issue identifier InboundApplier may route by: the comment's parent
    # issue (data.issue.id / data.issueId), the Issue event's own id (data.id —
    # what update_issue!/remove_issue!/create_issue! key on), and a create/
    # reparent target (data.parentId). The comment-shaped extract_issue_id alone
    # missed data.id, letting an Issue payload signed with team A's secret but
    # naming team B's issue slip past the cross-team guard.
    def issue_ids_in_payload(payload)
      ids = [ extract_issue_id(payload), payload.dig("data", "parentId") ]
      ids << payload.dig("data", "id") if payload["type"] == "Issue"
      ids.compact_blank
    end

    # Comment events route update/remove by the Comment's own data.id (a
    # linear_comment_id), which none of the issue-shaped extractors surface.
    # Without checking it, a payload signed with team A's secret but naming team
    # B's CommentLink slips past the guard and apply_comment! edits/deletes B's
    # mirror. Only a Comment payload's data.id is a comment id (Issue payloads key
    # it as an issue, already covered above).
    def comment_ids_in_payload(payload)
      return [] unless payload["type"] == "Comment"

      [ payload.dig("data", "id") ].compact_blank
    end

    def extract_issue_id(payload)
      payload.dig("data", "issue", "id") || payload.dig("data", "issueId")
    end

    def extract_team_id(payload)
      payload.dig("data", "teamId") ||
        payload.dig("data", "team", "id") ||
        payload["teamId"]
    end

    def extract_project_id(payload)
      payload.dig("data", "projectId") ||
        payload.dig("data", "project", "id")
    end

    def resolve_account(link)
      link&.account || CollavreLinear::Account.first
    end

    def valid_signature?(raw_body, secret)
      return false if secret.blank?

      signature = request.headers["Linear-Signature"] ||
        request.get_header("HTTP_LINEAR_SIGNATURE")
      return false if signature.blank?

      expected = OpenSSL::HMAC.hexdigest("SHA256", secret, raw_body)
      ActiveSupport::SecurityUtils.secure_compare(expected, signature)
    end

    def fresh_timestamp?(payload)
      ts = payload["webhookTimestamp"]
      return false if ts.blank?

      ts_ms = Integer(ts)
      now_ms = (Time.now.to_f * 1000).to_i
      (now_ms - ts_ms).abs <= TIMESTAMP_WINDOW_MS
    rescue ArgumentError, TypeError
      false
    end
  end
end
