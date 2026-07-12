# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module CollavreLinear
  class Client
    # Raised when the GraphQL response includes an `errors` array.
    class Error < StandardError; end

    DEFAULT_ENDPOINT = "https://api.linear.app/graphql"

    # ---------------------------------------------------------------------------
    # GraphQL operation strings
    # NOTE: All *Input field names below must be verified against the Live Linear
    # Apollo schema before production use. Field names are conventional based on
    # the public Linear GraphQL documentation but have NOT been validated against
    # the live schema in this implementation.
    # ---------------------------------------------------------------------------

    # IssueCreateInput fields used: teamId, title, description, parentId,
    # projectId, stateId, assigneeId, labelIds, priority
    ISSUE_CREATE = <<~GQL.freeze
      mutation IssueCreate($input: IssueCreateInput!) {
        issueCreate(input: $input) {
          success
          issue {
            id
            identifier
            updatedAt
          }
        }
      }
    GQL

    # IssueUpdateInput fields used: title, description, parentId, projectId,
    # stateId, assigneeId, labelIds, priority (any subset passed as **fields)
    ISSUE_UPDATE = <<~GQL.freeze
      mutation IssueUpdate($id: String!, $input: IssueUpdateInput!) {
        issueUpdate(id: $id, input: $input) {
          success
          issue {
            id
            identifier
            updatedAt
          }
        }
      }
    GQL

    # ProjectCreateInput fields used: name, teamIds
    PROJECT_CREATE = <<~GQL.freeze
      mutation ProjectCreate($input: ProjectCreateInput!) {
        projectCreate(input: $input) {
          success
          project {
            id
          }
        }
      }
    GQL

    # ProjectUpdateInput fields used: name (any subset passed as **fields)
    PROJECT_UPDATE = <<~GQL.freeze
      mutation ProjectUpdate($id: String!, $input: ProjectUpdateInput!) {
        projectUpdate(id: $id, input: $input) {
          success
          project {
            id
          }
        }
      }
    GQL

    # CommentCreateInput fields used: issueId, body
    COMMENT_CREATE = <<~GQL.freeze
      mutation CommentCreate($input: CommentCreateInput!) {
        commentCreate(input: $input) {
          success
          comment {
            id
            updatedAt
          }
        }
      }
    GQL

    # CommentUpdateInput fields used: body
    COMMENT_UPDATE = <<~GQL.freeze
      mutation CommentUpdate($id: String!, $input: CommentUpdateInput!) {
        commentUpdate(id: $id, input: $input) {
          success
          comment {
            id
            updatedAt
          }
        }
      }
    GQL

    COMMENT_DELETE = <<~GQL.freeze
      mutation CommentDelete($id: String!) {
        commentDelete(id: $id) {
          success
        }
      }
    GQL

    # WebhookCreateInput fields used: url, secret, teamId, resourceTypes
    WEBHOOK_CREATE = <<~GQL.freeze
      mutation WebhookCreate($input: WebhookCreateInput!) {
        webhookCreate(input: $input) {
          success
          webhook {
            id
          }
        }
      }
    GQL

    # Archive (soft-delete) a Linear issue by id.
    ISSUE_ARCHIVE = <<~GQL.freeze
      mutation IssueArchive($id: String!) {
        issueArchive(id: $id) {
          success
        }
      }
    GQL

    # Delete (deregister) a Linear webhook by id.
    WEBHOOK_DELETE = <<~GQL.freeze
      mutation WebhookDelete($id: String!) {
        webhookDelete(id: $id) {
          success
        }
      }
    GQL

    # Delete (deregister) a webhook from Linear.
    # @param id [String] Linear webhook UUID
    # @return [Boolean] success
    def delete_webhook(id)
      data = post!(WEBHOOK_DELETE, { id: id })
      data.dig("webhookDelete", "success") == true
    end

    # Viewer identity only. Linear's schema exposes no Query field for the OAuth
    # app actor id of the current token (`applicationWithAuthorization { appActor }`
    # is not valid — that field is absent and its type carries no appActor), so
    # app_actor_id stays nil and EchoGuard no-ops. Loops are already prevented
    # independently by InboundApplier (skip_linear_sync on inbound writes,
    # IssueLink dedup on create, content_hash on update).
    VIEWER = <<~GQL.freeze
      query Viewer {
        viewer {
          id
          organization {
            id
          }
        }
      }
    GQL

    # List the workspace teams the token can see (for the link-a-project picker).
    TEAMS = <<~GQL.freeze
      query Teams {
        teams(first: 250) {
          nodes {
            id
            name
            key
          }
        }
      }
    GQL

    # List projects with their owning team ids so the picker can scope projects
    # to the chosen team (a Linear project may belong to more than one team).
    PROJECTS = <<~GQL.freeze
      query Projects {
        projects(first: 250) {
          nodes {
            id
            name
            teams {
              nodes { id }
            }
          }
        }
      }
    GQL

    def initialize(account)
      @account = account
      @endpoint = resolve_endpoint
    end

    # Create a Linear issue.
    # @return [Hash] with :id and :identifier
    def create_issue(team_id:, title:, description: nil, parent_id: nil,
                     project_id: nil, state_id: nil, assignee_id: nil,
                     label_ids: [], priority: nil)
      input = { teamId: team_id, title: title }.tap do |h|
        h[:description] = description if description
        h[:parentId]    = parent_id   if parent_id
        h[:projectId]   = project_id  if project_id
        h[:stateId]     = state_id    if state_id
        h[:assigneeId]  = assignee_id if assignee_id
        h[:labelIds]    = label_ids   if label_ids.any?
        h[:priority]    = priority    if priority
      end

      data = post!(ISSUE_CREATE, { input: input })
      node = data.dig("issueCreate", "issue")
      symbolize(node)
    end

    # Update a Linear issue by id.
    # @param id [String] Linear issue UUID
    # @param fields [Hash] keyword args mapping to IssueUpdateInput fields
    # @return [Hash] with :id and :identifier
    def update_issue(id, **fields)
      input = camelize_keys(fields)
      data  = post!(ISSUE_UPDATE, { id: id, input: input })
      node  = data.dig("issueUpdate", "issue")
      symbolize(node)
    end

    # Create a Linear project.
    # @return [Hash] with :id
    def create_project(name:, team_ids:)
      input = { name: name, teamIds: team_ids }
      data  = post!(PROJECT_CREATE, { input: input })
      node  = data.dig("projectCreate", "project")
      symbolize(node)
    end

    # Update a Linear project by id.
    # @param id [String] Linear project UUID
    # @param fields [Hash] keyword args mapping to ProjectUpdateInput fields
    # @return [Hash] with :id
    def update_project(id, **fields)
      input = camelize_keys(fields)
      data  = post!(PROJECT_UPDATE, { id: id, input: input })
      node  = data.dig("projectUpdate", "project")
      symbolize(node)
    end

    # Archive a Linear issue (soft-delete).
    # @param id [String] Linear issue UUID
    # @return [Boolean] success
    def archive_issue(id)
      data = post!(ISSUE_ARCHIVE, { id: id })
      data.dig("issueArchive", "success") == true
    end

    # Create a comment on a Linear issue.
    # @return [Hash] with :id
    def create_comment(issue_id:, body:)
      input = { issueId: issue_id, body: body }
      data  = post!(COMMENT_CREATE, { input: input })
      node  = data.dig("commentCreate", "comment")
      symbolize(node)
    end

    # Edit an existing Linear comment's body.
    # @return [Hash] with :id
    def update_comment(id:, body:)
      data = post!(COMMENT_UPDATE, { id: id, input: { body: body } })
      node = data.dig("commentUpdate", "comment")
      symbolize(node)
    end

    # Delete a Linear comment.
    # @return [Boolean] success
    def delete_comment(id)
      data = post!(COMMENT_DELETE, { id: id })
      data.dig("commentDelete", "success") == true
    end

    # Fetch the authenticated viewer identity.
    # app_actor_id is intentionally nil (no Linear query exposes it for the
    # current token); EchoGuard degrades to a no-op — see VIEWER above.
    # @return [Hash] with :user_id, :app_actor_id, :organization_id
    def viewer_and_app_actor
      data = post!(VIEWER, {})
      {
        user_id:         data.dig("viewer", "id"),
        organization_id: data.dig("viewer", "organization", "id"),
        app_actor_id:    nil
      }
    end

    # List workspace teams for the link picker.
    # @return [Array<Hash>] each with :id, :name, :key
    def list_teams
      data  = post!(TEAMS, {})
      nodes = data.dig("teams", "nodes") || []
      nodes.map { |n| symbolize(n) }
    end

    # List projects for the link picker, each with the ids of its owning teams
    # so the UI can scope projects to the selected team.
    # @return [Array<Hash>] each with :id, :name, :team_ids
    def list_projects
      data  = post!(PROJECTS, {})
      nodes = data.dig("projects", "nodes") || []
      nodes.map do |n|
        {
          id:       n["id"],
          name:     n["name"],
          team_ids: (n.dig("teams", "nodes") || []).map { |t| t["id"] }
        }
      end
    end

    # Register a webhook with Linear.
    # WebhookCreateInput fields: url, secret, teamId, resourceTypes
    # @return [Hash] with :id
    def register_webhook(url:, secret:, team_id:, resource_types:)
      input = { url: url, secret: secret, teamId: team_id, resourceTypes: resource_types }
      data  = post!(WEBHOOK_CREATE, { input: input })
      node  = data.dig("webhookCreate", "webhook")
      symbolize(node)
    end

    private

    attr_reader :account, :endpoint

    # Execute a GraphQL operation and return the `data` hash.
    # Raises Client::Error if the response contains a top-level `errors` key.
    def post!(query, variables)
      token = fresh_access_token

      response =
        begin
          http_client.post(
            endpoint,
            body: { query: query, variables: variables }.to_json,
            headers: {
              "Content-Type" => "application/json",
              "Authorization" => "Bearer #{token}"
            }
          )
        rescue Collavre::HttpClient::ConnectionError => e
          # Transport-layer failures (connection refused/reset, DNS, TLS,
          # open/read timeouts) raise before any GraphQL response exists, so they
          # bypass the parsed-`errors` path below. Wrap them in Error so the
          # outbound jobs' `retry_on Client::Error` treats a transient
          # Linear/network outage as retryable instead of dropping the pending
          # sync/comment/archive on the first failure.
          raise Error, "Linear transport error: #{e.class}: #{e.message}"
        end

      parsed = begin
        JSON.parse(response.body)
      rescue JSON::ParserError
        raise Error, "Linear returned non-JSON response (HTTP #{response.code}): #{response.body.to_s[0, 200]}"
      end

      if parsed["errors"].present?
        messages = parsed["errors"].map { |e| e["message"] }.join("; ")
        raise Error, "Linear GraphQL error(s): #{messages}"
      end

      unless response.success?
        raise Error, "Linear HTTP error: #{response.code} #{response.message}"
      end

      parsed["data"]
    end

    # Shared Net::HTTP wrapper preserving Linear's original 10s connect / 30s
    # read timeouts.
    def http_client
      @http_client ||= Collavre::HttpClient.new(open_timeout: 10, read_timeout: 30)
    end

    # Return a non-expired access token, refreshing via the refresh_token grant
    # when the current token is expiring soon.
    #
    # Guards:
    #   - no refresh_token present  → use current token (nothing to refresh with)
    #   - nil token_expires_at      → long-lived token, never triggers a refresh
    #     (Account#token_expiring_soon? returns false for a nil expiry)
    def fresh_access_token
      if account.refresh_token.present? && account.token_expiring_soon?
        begin
          CollavreLinear::OAuthTokenService.refresh(account)
        rescue CollavreLinear::OAuthTokenService::Error,
               SocketError, SystemCallError, Timeout::Error, IOError,
               OpenSSL::SSL::SSLError => e
          # The refresh runs before the GraphQL request, so a transient failure
          # here (network/TLS/timeout, or a temporary non-2xx from Linear's token
          # endpoint) raises outside post!'s transport wrap and would bypass the
          # outbound jobs' retry_on Client::Error, dropping the pending sync. Map
          # it to Error so a transient outage is retried, not lost.
          raise Error, "Linear token refresh failed: #{e.class}: #{e.message}"
        end
      end
      account.access_token
    end

    def resolve_endpoint
      if defined?(Collavre::IntegrationSettings::Resolver)
        Collavre::IntegrationSettings::Resolver.get(:linear_api_endpoint).presence
      end || DEFAULT_ENDPOINT
    end

    # Convert symbol keys to camelCase strings for GraphQL variables.
    # e.g. :team_id => "teamId"
    def camelize_keys(hash)
      hash.transform_keys { |k| camelize(k.to_s) }
    end

    def camelize(str)
      parts = str.split("_")
      parts[0] + parts[1..].map(&:capitalize).join
    end

    def symbolize(hash)
      return {} if hash.nil?
      hash.transform_keys(&:to_sym)
    end
  end
end
