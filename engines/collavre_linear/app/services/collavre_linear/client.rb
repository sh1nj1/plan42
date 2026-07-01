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
          }
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

    # viewer query + applicationWithAuthorization for OAuth app actor
    VIEWER = <<~GQL.freeze
      query ViewerAndAppActor {
        viewer {
          id
          organization {
            id
          }
        }
        applicationWithAuthorization {
          appActor {
            id
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

    # Create a comment on a Linear issue.
    # @return [Hash] with :id
    def create_comment(issue_id:, body:)
      input = { issueId: issue_id, body: body }
      data  = post!(COMMENT_CREATE, { input: input })
      node  = data.dig("commentCreate", "comment")
      symbolize(node)
    end

    # Fetch the authenticated viewer identity and OAuth app actor.
    # @return [Hash] with :user_id, :app_actor_id, :organization_id
    def viewer_and_app_actor
      data = post!(VIEWER, {})
      {
        user_id:         data.dig("viewer", "id"),
        organization_id: data.dig("viewer", "organization", "id"),
        app_actor_id:    data.dig("applicationWithAuthorization", "appActor", "id")
      }
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
      uri  = URI.parse(endpoint)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"

      request = Net::HTTP::Post.new(uri.path.presence || "/")
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{account.access_token}"
      request.body = { query: query, variables: variables }.to_json

      response = http.request(request)
      parsed   = JSON.parse(response.body)

      if parsed["errors"].present?
        messages = parsed["errors"].map { |e| e["message"] }.join("; ")
        raise Error, "Linear GraphQL error(s): #{messages}"
      end

      parsed["data"]
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
