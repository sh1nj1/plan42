# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

# Disable net connections during client tests; all HTTP must be stubbed.
WebMock.disable_net_connect!

module CollavreLinear
  class ClientTest < ActiveSupport::TestCase
    LINEAR_ENDPOINT = "https://api.linear.app/graphql"

    def setup
      @user = Collavre.user_class.create!(
        email: "linear-client-test@example.com",
        name: "Linear Client Test",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD,
        timezone: "UTC"
      )
      @account = CollavreLinear::Account.new(
        user: @user,
        linear_uid: "usr_client_test",
        access_token: "tok"
      )
      @client = CollavreLinear::Client.new(@account)

      ENV["LINEAR_CLIENT_ID"]          ||= "test-client-id"
      ENV["LINEAR_CLIENT_SECRET"]      ||= "test-client-secret"
      ENV["LINEAR_OAUTH_REDIRECT_URI"] ||= "https://example.com/linear/auth/callback"
    end

    # ---------------------------------------------------------------------------
    # create_issue
    # ---------------------------------------------------------------------------
    test "create_issue posts issueCreate mutation and returns id" do
      stub_request(:post, LINEAR_ENDPOINT)
        .with(headers: { "Authorization" => "Bearer tok" })
        .to_return(
          status: 200,
          body: {
            data: { issueCreate: { success: true, issue: { id: "iss-1", identifier: "ENG-1" } } }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      res = @client.create_issue(team_id: "t1", title: "Hi")

      assert_equal "iss-1", res[:id]
      assert_equal "ENG-1", res[:identifier]
      assert_requested :post, LINEAR_ENDPOINT, body: /issueCreate/, times: 1
    end

    test "create_issue sends description and optional fields when provided" do
      stub_request(:post, LINEAR_ENDPOINT)
        .to_return(
          status: 200,
          body: {
            data: { issueCreate: { success: true, issue: { id: "iss-2", identifier: "ENG-2" } } }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      res = @client.create_issue(
        team_id: "t1",
        title: "With all fields",
        description: "body text",
        parent_id: "iss-0",
        project_id: "proj-1",
        state_id: "state-1",
        assignee_id: "user-1",
        label_ids: [ "lbl-1" ],
        priority: 2
      )

      assert_equal "iss-2", res[:id]
      assert_requested :post, LINEAR_ENDPOINT do |req|
        body = JSON.parse(req.body)
        vars = body["variables"]["input"]
        vars["teamId"] == "t1" &&
          vars["title"] == "With all fields" &&
          vars["description"] == "body text" &&
          vars["parentId"] == "iss-0" &&
          vars["projectId"] == "proj-1" &&
          vars["stateId"] == "state-1" &&
          vars["assigneeId"] == "user-1" &&
          vars["labelIds"] == [ "lbl-1" ] &&
          vars["priority"] == 2
      end
    end

    # ---------------------------------------------------------------------------
    # update_issue
    # ---------------------------------------------------------------------------
    test "update_issue posts issueUpdate mutation and returns id" do
      stub_request(:post, LINEAR_ENDPOINT)
        .with(headers: { "Authorization" => "Bearer tok" })
        .to_return(
          status: 200,
          body: {
            data: { issueUpdate: { success: true, issue: { id: "iss-1", identifier: "ENG-1" } } }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      res = @client.update_issue("iss-1", title: "Updated")

      assert_equal "iss-1", res[:id]
      assert_requested :post, LINEAR_ENDPOINT, body: /issueUpdate/, times: 1
    end

    # ---------------------------------------------------------------------------
    # create_project
    # ---------------------------------------------------------------------------
    test "create_project posts projectCreate mutation and returns id" do
      stub_request(:post, LINEAR_ENDPOINT)
        .with(headers: { "Authorization" => "Bearer tok" })
        .to_return(
          status: 200,
          body: {
            data: { projectCreate: { success: true, project: { id: "proj-1" } } }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      res = @client.create_project(name: "My Project", team_ids: [ "t1" ])

      assert_equal "proj-1", res[:id]
      assert_requested :post, LINEAR_ENDPOINT, body: /projectCreate/, times: 1
    end

    # ---------------------------------------------------------------------------
    # update_project
    # ---------------------------------------------------------------------------
    test "update_project posts projectUpdate mutation and returns id" do
      stub_request(:post, LINEAR_ENDPOINT)
        .with(headers: { "Authorization" => "Bearer tok" })
        .to_return(
          status: 200,
          body: {
            data: { projectUpdate: { success: true, project: { id: "proj-1" } } }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      res = @client.update_project("proj-1", name: "Renamed")

      assert_equal "proj-1", res[:id]
      assert_requested :post, LINEAR_ENDPOINT, body: /projectUpdate/, times: 1
    end

    # ---------------------------------------------------------------------------
    # create_comment
    # ---------------------------------------------------------------------------
    test "create_comment posts commentCreate mutation and returns id" do
      stub_request(:post, LINEAR_ENDPOINT)
        .with(headers: { "Authorization" => "Bearer tok" })
        .to_return(
          status: 200,
          body: {
            data: { commentCreate: { success: true, comment: { id: "cmt-1" } } }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      res = @client.create_comment(issue_id: "iss-1", body: "Hello!")

      assert_equal "cmt-1", res[:id]
      assert_requested :post, LINEAR_ENDPOINT, body: /commentCreate/, times: 1
    end

    # ---------------------------------------------------------------------------
    # update_comment
    # ---------------------------------------------------------------------------
    test "update_comment posts commentUpdate mutation and returns id" do
      stub_request(:post, LINEAR_ENDPOINT)
        .with(headers: { "Authorization" => "Bearer tok" }) do |req|
          req.body.include?("commentUpdate") && req.body.include?("edited body")
        end
        .to_return(
          status: 200,
          body: {
            data: { commentUpdate: { success: true, comment: { id: "cmt-1" } } }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      res = @client.update_comment(id: "cmt-1", body: "edited body")

      assert_equal "cmt-1", res[:id]
      assert_requested :post, LINEAR_ENDPOINT, body: /commentUpdate/, times: 1
    end

    # ---------------------------------------------------------------------------
    # delete_comment
    # ---------------------------------------------------------------------------
    test "delete_comment posts commentDelete mutation and returns success" do
      stub_request(:post, LINEAR_ENDPOINT)
        .with(headers: { "Authorization" => "Bearer tok" }) do |req|
          req.body.include?("commentDelete") && req.body.include?("cmt-1")
        end
        .to_return(
          status: 200,
          body: { data: { commentDelete: { success: true } } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      assert_equal true, @client.delete_comment("cmt-1")
      assert_requested :post, LINEAR_ENDPOINT, body: /commentDelete/, times: 1
    end

    # ---------------------------------------------------------------------------
    # viewer_and_app_actor
    # ---------------------------------------------------------------------------
    test "viewer_and_app_actor returns user_id and organization_id; app_actor_id nil" do
      # Linear's schema has no Query field for the app actor id, so the request
      # asks only for viewer identity and app_actor_id is always nil.
      stub_request(:post, LINEAR_ENDPOINT)
        .with(headers: { "Authorization" => "Bearer tok" }) do |req|
          !req.body.include?("applicationWithAuthorization")
        end
        .to_return(
          status: 200,
          body: {
            data: {
              viewer: {
                id: "user-123",
                organization: { id: "org-456" }
              }
            }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      res = @client.viewer_and_app_actor

      assert_equal "user-123", res[:user_id]
      assert_equal "org-456", res[:organization_id]
      assert_nil res[:app_actor_id]
    end

    # ---------------------------------------------------------------------------
    # list_teams / list_projects (link picker)
    # ---------------------------------------------------------------------------
    test "list_teams returns id/name/key for each team" do
      stub_request(:post, LINEAR_ENDPOINT)
        .with(body: /teams/)
        .to_return(
          status: 200,
          body: {
            data: { teams: { nodes: [
              { id: "t1", name: "Engineering", key: "ENG" },
              { id: "t2", name: "Design", key: "DSN" }
            ] } }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      teams = @client.list_teams

      assert_equal 2, teams.size
      assert_equal "t1", teams.first[:id]
      assert_equal "Engineering", teams.first[:name]
      assert_equal "ENG", teams.first[:key]
    end

    test "list_projects returns id/name and owning team_ids" do
      stub_request(:post, LINEAR_ENDPOINT)
        .with(body: /projects/)
        .to_return(
          status: 200,
          body: {
            data: { projects: { nodes: [
              { id: "p1", name: "Roadmap", teams: { nodes: [ { id: "t1" }, { id: "t2" } ] } },
              { id: "p2", name: "Backlog", teams: { nodes: [ { id: "t2" } ] } }
            ] } }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      projects = @client.list_projects

      assert_equal 2, projects.size
      assert_equal "p1", projects.first[:id]
      assert_equal "Roadmap", projects.first[:name]
      assert_equal %w[t1 t2], projects.first[:team_ids]
      assert_equal %w[t2], projects.last[:team_ids]
    end

    test "list_teams returns [] when nodes are absent" do
      stub_request(:post, LINEAR_ENDPOINT)
        .to_return(
          status: 200,
          body: { data: { teams: {} } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      assert_equal [], @client.list_teams
    end

    # ---------------------------------------------------------------------------
    # register_webhook
    # ---------------------------------------------------------------------------
    test "register_webhook posts webhookCreate mutation and returns id" do
      stub_request(:post, LINEAR_ENDPOINT)
        .with(headers: { "Authorization" => "Bearer tok" })
        .to_return(
          status: 200,
          body: {
            data: { webhookCreate: { success: true, webhook: { id: "wh-1" } } }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      res = @client.register_webhook(
        url: "https://example.com/hook",
        secret: "s3cr3t",
        team_id: "t1",
        resource_types: [ "Issue" ]
      )

      assert_equal "wh-1", res[:id]
      assert_requested :post, LINEAR_ENDPOINT, body: /webhookCreate/, times: 1
    end

    # ---------------------------------------------------------------------------
    # archive_issue
    # ---------------------------------------------------------------------------
    test "archive_issue posts issueArchive mutation and returns true on success" do
      stub_request(:post, LINEAR_ENDPOINT)
        .with(headers: { "Authorization" => "Bearer tok" })
        .to_return(
          status: 200,
          body: {
            data: { issueArchive: { success: true } }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = @client.archive_issue("iss-to-archive")

      assert_equal true, result
      assert_requested :post, LINEAR_ENDPOINT, body: /issueArchive/, times: 1
      assert_requested :post, LINEAR_ENDPOINT do |req|
        body = JSON.parse(req.body)
        body["variables"]["id"] == "iss-to-archive"
      end
    end

    # ---------------------------------------------------------------------------
    # delete_webhook
    # ---------------------------------------------------------------------------
    test "delete_webhook posts webhookDelete mutation and returns true on success" do
      stub_request(:post, LINEAR_ENDPOINT)
        .with(headers: { "Authorization" => "Bearer tok" })
        .to_return(
          status: 200,
          body: {
            data: { webhookDelete: { success: true } }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = @client.delete_webhook("wh-to-delete")

      assert_equal true, result
      assert_requested :post, LINEAR_ENDPOINT, body: /webhookDelete/, times: 1
      assert_requested :post, LINEAR_ENDPOINT do |req|
        body = JSON.parse(req.body)
        body["variables"]["id"] == "wh-to-delete"
      end
    end

    test "delete_webhook raises Client::Error on GraphQL errors" do
      stub_request(:post, LINEAR_ENDPOINT)
        .to_return(
          status: 200,
          body: {
            errors: [ { message: "Webhook not found" } ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      err = assert_raises(CollavreLinear::Client::Error) do
        @client.delete_webhook("wh-nonexistent")
      end

      assert_match "Webhook not found", err.message
    end

    # ---------------------------------------------------------------------------
    # Error handling
    # ---------------------------------------------------------------------------
    test "raises Client::Error when response contains GraphQL errors" do
      stub_request(:post, LINEAR_ENDPOINT)
        .to_return(
          status: 200,
          body: {
            errors: [
              { message: "Unauthorized" },
              { message: "Token expired" }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      err = assert_raises(CollavreLinear::Client::Error) do
        @client.create_issue(team_id: "t1", title: "Boom")
      end

      assert_match "Unauthorized", err.message
      assert_match "Token expired", err.message
    end

    test "raises Client::Error even when data is also present alongside errors" do
      stub_request(:post, LINEAR_ENDPOINT)
        .to_return(
          status: 200,
          body: {
            data: { issueCreate: nil },
            errors: [ { message: "Partial failure" } ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      assert_raises(CollavreLinear::Client::Error) do
        @client.create_issue(team_id: "t1", title: "Partial")
      end
    end

    test "raises Client::Error (not JSON::ParserError) on 401 with non-GraphQL body" do
      stub_request(:post, LINEAR_ENDPOINT)
        .to_return(
          status: 401,
          body: { error: "unauthorized" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      err = assert_raises(CollavreLinear::Client::Error) do
        @client.create_issue(team_id: "t1", title: "Auth failure")
      end

      assert_match "401", err.message
    end

    test "raises Client::Error on 401 with HTML body (non-JSON)" do
      stub_request(:post, LINEAR_ENDPOINT)
        .to_return(
          status: 401,
          body: "<html><body>Unauthorized</body></html>",
          headers: { "Content-Type" => "text/html" }
        )

      err = assert_raises(CollavreLinear::Client::Error) do
        @client.create_issue(team_id: "t1", title: "HTML auth failure")
      end

      assert_match "401", err.message
      assert_kind_of CollavreLinear::Client::Error, err
    end

    test "raises Client::Error on 500 response" do
      stub_request(:post, LINEAR_ENDPOINT)
        .to_return(
          status: 500,
          body: { error: "Internal Server Error" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      err = assert_raises(CollavreLinear::Client::Error) do
        @client.create_issue(team_id: "t1", title: "Server error")
      end

      assert_match "500", err.message
    end

    test "wraps a connection/read timeout in Client::Error so outbound jobs retry" do
      # Transport failures raise before any GraphQL response is parsed. They must
      # surface as Client::Error, otherwise the outbound jobs' retry_on
      # Client::Error can't catch them and a transient outage drops the change.
      stub_request(:post, LINEAR_ENDPOINT).to_timeout

      err = assert_raises(CollavreLinear::Client::Error) do
        @client.create_issue(team_id: "t1", title: "Timeout")
      end
      assert_match(/transport error/, err.message)
    end

    test "wraps a socket/connection error in Client::Error so outbound jobs retry" do
      stub_request(:post, LINEAR_ENDPOINT).to_raise(Errno::ECONNREFUSED)

      assert_raises(CollavreLinear::Client::Error) do
        @client.create_issue(team_id: "t1", title: "Conn refused")
      end
    end

    # ---------------------------------------------------------------------------
    # Token refresh (P1-1)
    # ---------------------------------------------------------------------------
    LINEAR_TOKEN_ENDPOINT = "https://api.linear.app/oauth/token"

    test "refreshes an expiring token before posting the GraphQL request" do
      account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "usr_refresh_test",
        access_token: "stale-tok",
        refresh_token: "refresh-tok",
        token_expires_at: 10.seconds.from_now
      )
      client = CollavreLinear::Client.new(account)

      token_stub = stub_request(:post, LINEAR_TOKEN_ENDPOINT)
        .with(body: hash_including("grant_type" => "refresh_token"))
        .to_return(
          status: 200,
          body: { access_token: "fresh-tok", expires_in: 3600 }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      graphql_stub = stub_request(:post, LINEAR_ENDPOINT)
        .with(headers: { "Authorization" => "Bearer fresh-tok" })
        .to_return(
          status: 200,
          body: {
            data: { issueCreate: { success: true, issue: { id: "iss-r", identifier: "ENG-R" } } }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      client.create_issue(team_id: "t1", title: "Refresh me")

      assert_requested(token_stub, times: 1)
      assert_requested(graphql_stub, times: 1)
      assert_equal "fresh-tok", account.reload.access_token
    end

    test "does not refresh a non-expiring token" do
      account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "usr_no_refresh_test",
        access_token: "live-tok",
        refresh_token: "refresh-tok",
        token_expires_at: 1.hour.from_now
      )
      client = CollavreLinear::Client.new(account)

      stub_request(:post, LINEAR_ENDPOINT)
        .with(headers: { "Authorization" => "Bearer live-tok" })
        .to_return(
          status: 200,
          body: {
            data: { issueCreate: { success: true, issue: { id: "iss-n", identifier: "ENG-N" } } }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      client.create_issue(team_id: "t1", title: "No refresh")

      assert_not_requested :post, LINEAR_TOKEN_ENDPOINT
    end

    test "does not refresh when token_expires_at is nil (long-lived token)" do
      account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "usr_longlived_test",
        access_token: "longlived-tok",
        refresh_token: "refresh-tok",
        token_expires_at: nil
      )
      client = CollavreLinear::Client.new(account)

      stub_request(:post, LINEAR_ENDPOINT)
        .with(headers: { "Authorization" => "Bearer longlived-tok" })
        .to_return(
          status: 200,
          body: {
            data: { issueCreate: { success: true, issue: { id: "iss-l", identifier: "ENG-L" } } }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      client.create_issue(team_id: "t1", title: "Long lived")

      assert_not_requested :post, LINEAR_TOKEN_ENDPOINT
    end

    # ---------------------------------------------------------------------------
    # Content-Type header
    # ---------------------------------------------------------------------------
    test "sends Content-Type application/json header" do
      stub_request(:post, LINEAR_ENDPOINT)
        .with(headers: { "Content-Type" => "application/json" })
        .to_return(
          status: 200,
          body: {
            data: { issueCreate: { success: true, issue: { id: "iss-3", identifier: "ENG-3" } } }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      @client.create_issue(team_id: "t1", title: "Header check")
      assert_requested :post, LINEAR_ENDPOINT,
        headers: { "Content-Type" => "application/json" }, times: 1
    end
  end
end
