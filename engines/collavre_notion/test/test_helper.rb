ENV["RAILS_ENV"] ||= "test"
require_relative "../../../test/test_helper"
require "collavre_notion"
require "webmock/minitest"
# Allow net connections by default so other engines' tests are not affected.
WebMock.allow_net_connect!

module CollavreNotionTestHelpers
  def create_user(email: "user@example.com", name: "Test User")
    Collavre.user_class.create!(
      email: email,
      name: name,
      password: TEST_PASSWORD,
      password_confirmation: TEST_PASSWORD,
      timezone: "UTC"
    )
  end

  def create_creative(user)
    Collavre::Creative.create!(
      description: "Notion test creative",
      progress: 0.0,
      user: user
    )
  end

  def create_notion_account(user, workspace_name: "Test Workspace", token: "fake-notion-token")
    CollavreNotion::NotionAccount.create!(
      user: user,
      notion_uid: "notion-#{user.id}-001",
      workspace_name: workspace_name,
      token: token
    )
  end

  # Stub Notion search pages API
  def stub_notion_search(pages, query: nil)
    stub_request(:post, %r{/v1/search})
      .to_return(
        status: 200,
        body: { "object" => "list", "results" => pages, "has_more" => false, "next_cursor" => nil }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  # Stub Notion get page API
  def stub_notion_get_page(page_id, page_data)
    stub_request(:get, %r{/v1/pages/#{page_id}})
      .to_return(
        status: 200,
        body: page_data.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  # Stub Notion create page API
  def stub_notion_create_page
    stub_request(:post, %r{/v1/pages})
      .to_return(
        status: 200,
        body: {
          "object" => "page",
          "id" => SecureRandom.uuid,
          "url" => "https://www.notion.so/Test-Page-#{SecureRandom.hex(4)}",
          "properties" => {}
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  # Stub Notion get page blocks API
  def stub_notion_get_blocks(page_id, blocks: [])
    stub_request(:get, %r{/v1/blocks/#{page_id}/children})
      .to_return(
        status: 200,
        body: { "object" => "list", "results" => blocks, "has_more" => false, "next_cursor" => nil }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  # Stub Notion append blocks API
  def stub_notion_append_blocks(page_id)
    stub_request(:patch, %r{/v1/blocks/#{page_id}/children})
      .to_return(
        status: 200,
        body: { "object" => "list", "results" => [ { "id" => SecureRandom.uuid, "object" => "block" } ] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  # Stub Notion users/me API
  def stub_notion_bot_user
    stub_request(:get, %r{/v1/users/me})
      .to_return(
        status: 200,
        body: {
          "object" => "user", "id" => SecureRandom.uuid, "type" => "bot",
          "bot" => { "owner" => { "type" => "workspace", "workspace" => true }, "workspace_name" => "Test Workspace" },
          "name" => "Test Bot"
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  def mock_notion_page(id:, title:)
    {
      "object" => "page",
      "id" => id,
      "url" => "https://www.notion.so/#{title.tr(' ', '-')}-#{SecureRandom.hex(4)}",
      "parent" => { "type" => "workspace", "workspace" => true },
      "properties" => {
        "title" => { "title" => [ { "text" => { "content" => title } } ] }
      }
    }
  end
end

class ActiveSupport::TestCase
  include CollavreNotionTestHelpers
end

class ActionDispatch::IntegrationTest
  # Notion engine routes - use notion_engine.path_helper for Notion-specific routes
  def notion_engine
    CollavreNotion::Engine.routes.url_helpers
  end
end

class ActionDispatch::SystemTestCase
  include CollavreNotionTestHelpers
end
