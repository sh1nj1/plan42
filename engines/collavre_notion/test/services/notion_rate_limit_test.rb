require_relative "../test_helper"

class NotionRateLimitTest < ActiveSupport::TestCase
  setup do
    @user = create_user
    create_notion_account(@user)
    @service = CollavreNotion::NotionService.new(user: @user)
  end

  test "honors Retry-After and retries a rate-limited request" do
    request = stub_request(:post, %r{/v1/pages$})
      .to_return(status: 429, body: "{}", headers: { "Retry-After" => "4" })
      .then.to_return(status: 200, body: '{"id":"page"}', headers: { "Content-Type" => "application/json" })
    delays = []
    @service.stub(:sleep, ->(seconds) { delays << seconds }) do
      assert_equal "page", @service.create_page(parent_id: "parent", title: "Title")["id"]
    end
    assert_equal [ 4.0 ], delays
    assert_requested request, times: 2
  end

  test "bounds inline retries so persistent rate limits reach job retry handling" do
    request = stub_request(:post, %r{/v1/pages$}).to_return(status: 429, body: "{}")
    delays = []
    @service.stub(:sleep, ->(seconds) { delays << seconds }) do
      assert_raises(CollavreNotion::NotionRateLimitError) { @service.create_page(parent_id: "parent", title: "Title") }
    end
    assert_equal [ 1.0 ] * 5, delays
    assert_requested request, times: 6
  end
end
