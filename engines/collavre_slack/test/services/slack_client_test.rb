require_relative "../test_helper"

module CollavreSlack
  class SlackClientTest < ActiveSupport::TestCase
    TOKEN = "xoxb-test-token"

    setup do
      @client = SlackClient.new(access_token: TOKEN)
    end

    # -- list_channels (single page) -----------------------------------------

    test "list_channels returns parsed response" do
      stub_request(:get, "https://slack.com/api/conversations.list")
        .with(
          query: { "limit" => "200", "types" => "public_channel,private_channel" },
          headers: { "Authorization" => "Bearer #{TOKEN}" }
        )
        .to_return(
          status: 200,
          body: { ok: true, channels: [{ id: "C01", name: "general" }], response_metadata: { next_cursor: "" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      response = @client.list_channels
      assert response[:ok]
      assert_equal 1, response[:channels].size
      assert_equal "general", response[:channels].first[:name]
    end

    test "list_channels passes cursor when provided" do
      stub_request(:get, "https://slack.com/api/conversations.list")
        .with(query: hash_including("cursor" => "abc123"))
        .to_return(
          status: 200,
          body: { ok: true, channels: [], response_metadata: { next_cursor: "" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      response = @client.list_channels(cursor: "abc123")
      assert response[:ok]
    end

    # -- list_all_channels (pagination) ---------------------------------------

    test "list_all_channels fetches single page" do
      page = [{ id: "C01", name: "general" }, { id: "C02", name: "random" }]

      stub_request(:get, "https://slack.com/api/conversations.list")
        .with(query: { "limit" => "200", "types" => "public_channel,private_channel" })
        .to_return(
          status: 200,
          body: { ok: true, channels: page, response_metadata: { next_cursor: "" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      channels = @client.list_all_channels
      assert_equal 2, channels.size
      assert_equal %w[C01 C02], channels.map { |c| c[:id] }
    end

    test "list_all_channels paginates through multiple pages" do
      page1 = [{ id: "C01", name: "general" }, { id: "C02", name: "random" }]
      page2 = [{ id: "C03", name: "engineering" }]
      page3 = [{ id: "C04", name: "design" }]

      # Page 1: no cursor, returns next_cursor
      stub_request(:get, "https://slack.com/api/conversations.list")
        .with(query: { "limit" => "200", "types" => "public_channel,private_channel" })
        .to_return(
          status: 200,
          body: { ok: true, channels: page1, response_metadata: { next_cursor: "cursor_2" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      # Page 2: cursor_2, returns cursor_3
      stub_request(:get, "https://slack.com/api/conversations.list")
        .with(query: hash_including("cursor" => "cursor_2"))
        .to_return(
          status: 200,
          body: { ok: true, channels: page2, response_metadata: { next_cursor: "cursor_3" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      # Page 3: cursor_3, empty next_cursor (last page)
      stub_request(:get, "https://slack.com/api/conversations.list")
        .with(query: hash_including("cursor" => "cursor_3"))
        .to_return(
          status: 200,
          body: { ok: true, channels: page3, response_metadata: { next_cursor: "" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      channels = @client.list_all_channels

      assert_equal 4, channels.size
      assert_equal %w[C01 C02 C03 C04], channels.map { |c| c[:id] }
      assert_equal %w[general random engineering design], channels.map { |c| c[:name] }
    end

    test "list_all_channels returns empty array on API error" do
      stub_request(:get, "https://slack.com/api/conversations.list")
        .with(query: hash_including("limit" => "200"))
        .to_return(
          status: 200,
          body: { ok: false, error: "invalid_auth" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      channels = @client.list_all_channels
      assert_equal [], channels
    end

    test "list_all_channels handles nil next_cursor" do
      stub_request(:get, "https://slack.com/api/conversations.list")
        .with(query: hash_including("limit" => "200"))
        .to_return(
          status: 200,
          body: { ok: true, channels: [{ id: "C01", name: "general" }], response_metadata: {} }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      channels = @client.list_all_channels
      assert_equal 1, channels.size
    end

    test "list_all_channels handles missing response_metadata" do
      stub_request(:get, "https://slack.com/api/conversations.list")
        .with(query: hash_including("limit" => "200"))
        .to_return(
          status: 200,
          body: { ok: true, channels: [{ id: "C01", name: "general" }] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      channels = @client.list_all_channels
      assert_equal 1, channels.size
    end

    # -- Error handling -------------------------------------------------------

    test "list_all_channels stops on mid-pagination error" do
      # Page 1 succeeds
      stub_request(:get, "https://slack.com/api/conversations.list")
        .with(query: { "limit" => "200", "types" => "public_channel,private_channel" })
        .to_return(
          status: 200,
          body: { ok: true, channels: [{ id: "C01", name: "general" }], response_metadata: { next_cursor: "cursor_2" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      # Page 2 fails
      stub_request(:get, "https://slack.com/api/conversations.list")
        .with(query: hash_including("cursor" => "cursor_2"))
        .to_return(
          status: 200,
          body: { ok: false, error: "ratelimited" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      channels = @client.list_all_channels

      # Should return whatever was collected before the error
      assert_equal 1, channels.size
      assert_equal "C01", channels.first[:id]
    end
  end
end
