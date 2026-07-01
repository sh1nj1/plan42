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
      secret  = link&.webhook_secret

      return head :unauthorized unless valid_signature?(raw_body, secret)
      return head :unauthorized unless fresh_timestamp?(payload)

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
        link = CollavreLinear::ProjectLink.find_by(team_id: team_id)
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
