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
        label_ids: ["lbl-1"],
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
          vars["labelIds"] == ["lbl-1"] &&
          vars["priority"] == 2
      end
    end

    # ---------------------------------------------------------------------------
    # update_issue
    # ---------------------------------------------------------------------------
    test "update_issue posts issueUpdate mutation and returns id" do
      stub_request(:post, LINEAR_ENDPOINT)
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
        .to_return(
          status: 200,
          body: {
            data: { projectCreate: { success: true, project: { id: "proj-1" } } }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      res = @client.create_project(name: "My Project", team_ids: ["t1"])

      assert_equal "proj-1", res[:id]
      assert_requested :post, LINEAR_ENDPOINT, body: /projectCreate/, times: 1
    end

    # ---------------------------------------------------------------------------
    # update_project
    # ---------------------------------------------------------------------------
    test "update_project posts projectUpdate mutation and returns id" do
      stub_request(:post, LINEAR_ENDPOINT)
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
    # viewer_and_app_actor
    # ---------------------------------------------------------------------------
    test "viewer_and_app_actor returns user_id, app_actor_id, organization_id" do
      stub_request(:post, LINEAR_ENDPOINT)
        .to_return(
          status: 200,
          body: {
            data: {
              viewer: {
                id: "user-123",
                organization: { id: "org-456" }
              },
              applicationWithAuthorization: {
                appActor: { id: "actor-789" }
              }
            }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      res = @client.viewer_and_app_actor

      assert_equal "user-123", res[:user_id]
      assert_equal "org-456", res[:organization_id]
      assert_equal "actor-789", res[:app_actor_id]
    end

    # ---------------------------------------------------------------------------
    # register_webhook
    # ---------------------------------------------------------------------------
    test "register_webhook posts webhookCreate mutation and returns id" do
      stub_request(:post, LINEAR_ENDPOINT)
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
        resource_types: ["Issue"]
      )

      assert_equal "wh-1", res[:id]
      assert_requested :post, LINEAR_ENDPOINT, body: /webhookCreate/, times: 1
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
            errors: [{ message: "Partial failure" }]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      assert_raises(CollavreLinear::Client::Error) do
        @client.create_issue(team_id: "t1", title: "Partial")
      end
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
