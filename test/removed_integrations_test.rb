require "test_helper"

class RemovedIntegrationsTest < ActiveSupport::TestCase
  test "removed engines do not register integrations or model associations" do
    assert Collavre::IntegrationRegistry.find(:github)
    assert Collavre.user_class.reflect_on_association(:github_account)

    %i[notion linear].each do |name|
      assert_nil Collavre::IntegrationRegistry.find(name)
      assert_nil Collavre.user_class.reflect_on_association(:"#{name}_account")
    end

    %i[notion_page_links notion_block_links linear_issue_links linear_project_links].each do |name|
      assert_nil Collavre::Creative.reflect_on_association(name)
    end
  end

  test "removed engines expose no integration settings or routes" do
    registry = Collavre::IntegrationSettings::Registry.instance
    %i[notion_client_id notion_client_secret notion_mock linear_client_id linear_client_secret linear_oauth_redirect_uri].each do |key|
      assert_nil registry.find(key)
    end

    { "/auth/notion/callback" => :post, "/linear/auth/callback" => :get,
      "/linear/webhook" => :post, "/notion/creatives/1/notion_integration" => :get }.each do |path, method|
      assert_raises(ActionController::RoutingError) do
        Rails.application.routes.recognize_path(path, method: method)
      end
    end
  end
  test "retained integration records do not prevent deleting users or creatives" do
    connection = ActiveRecord::Base.connection
    %w[notion_accounts linear_accounts notion_page_links notion_block_links linear_project_links linear_issue_links].each do |table|
      assert connection.table_exists?(table)
      assert_empty connection.foreign_keys(table).select { |key| %w[users creatives].include?(key.to_table) }
    end

    user = Collavre.user_class.create!(name: "Retired integrations", email: "retired@example.com", password: TEST_PASSWORD)
    notion_account = Class.new(ActiveRecord::Base) { self.table_name = "notion_accounts" }
    linear_account = Class.new(ActiveRecord::Base) { self.table_name = "linear_accounts" }
    notion = notion_account.create!(user_id: user.id, notion_uid: "retired", token: "unused")
    linear = linear_account.create!(user_id: user.id, linear_uid: "retired", access_token: "unused")
    creative = Collavre::Creative.create!(user: user, description: "Retired integration links")
    page_link = Class.new(ActiveRecord::Base) { self.table_name = "notion_page_links" }
    block_link = Class.new(ActiveRecord::Base) { self.table_name = "notion_block_links" }
    project_link = Class.new(ActiveRecord::Base) { self.table_name = "linear_project_links" }
    issue_link = Class.new(ActiveRecord::Base) { self.table_name = "linear_issue_links" }
    page = page_link.create!(creative_id: creative.id, notion_account_id: notion.id, page_id: "retired")
    block_link.create!(creative_id: creative.id, notion_page_link_id: page.id, block_id: "retired")
    project = project_link.create!(creative_id: creative.id, account_id: linear.id, linear_project_id: "retired", team_id: "retired")
    issue_link.create!(creative_id: creative.id, project_link_id: project.id, linear_issue_id: "retired")

    creative.destroy!
    [ page_link, block_link, project_link, issue_link ].each do |model|
      assert model.exists?(creative_id: creative.id)
    end

    user.destroy!

    assert notion_account.exists?(user_id: user.id)
    assert linear_account.exists?(user_id: user.id)
  end
end
