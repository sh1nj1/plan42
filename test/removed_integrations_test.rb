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
end
