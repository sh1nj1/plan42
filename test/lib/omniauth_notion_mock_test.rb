# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/omniauth/strategies/notion_mock")

# Strategies::NotionMock exists so that mocking Notion does not have to switch
# OmniAuth's global test_mode on, which would drag a really-configured GitHub or
# Google through the mock path too. That only works if the strategy answers for
# /auth/notion on its own — before it existed, no :notion provider was registered
# in mock mode at all and the request never reached OmniAuth.
class OmniAuthNotionMockTest < ActiveSupport::TestCase
  setup do
    @previous_test_mode = OmniAuth.config.test_mode
    OmniAuth.config.test_mode = false
    @downstream = nil
    @app = ->(env) { @downstream = env; [ 200, {}, [ "ok" ] ] }
  end

  teardown do
    OmniAuth.config.test_mode = @previous_test_mode
  end

  test "it registers under the notion name" do
    # The engine routes /auth/notion/callback to NotionAuthController and the
    # modal posts to /auth/notion; both are keyed on this name.
    assert_equal "notion", OmniAuth::Strategies::NotionMock.default_options.name
  end

  test "the request phase returns straight to the callback" do
    status, headers, = call_strategy("/auth/notion?popup=true")

    assert_equal 302, status
    assert_includes headers["Location"], "/auth/notion/callback"
  end

  test "the request phase stashes the popup flag the callback template reads" do
    session = {}
    call_strategy("/auth/notion?popup=true", session: session)

    assert_equal true, session[:oauth_popup]
  end

  test "the callback phase hands the app a Notion auth hash" do
    call_strategy("/auth/notion/callback")

    auth = @downstream["omniauth.auth"]
    assert_equal "notion", auth.provider
    assert_equal "notion-dev-user-001", auth.uid
    assert_equal "fake-notion-dev-token", auth.credentials.token
    assert_equal "Dev Workspace", auth.info.name
  end

  private

  def call_strategy(path, session: {})
    strategy = OmniAuth::Strategies::NotionMock.new(@app)
    strategy.call(Rack::MockRequest.env_for(path, "rack.session" => session))
  end
end
