require "test_helper"

class CommentsControllerEventTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "test@example.com", password: "password", name: "Test User")
    @creative = Creative.create!(user: @user, description: "Test Creative")
    sign_in_as @user, password: "password"
  end

  test "dispatches comment_created event on successful creation" do
    # Mock Dispatcher
    mock = Minitest::Mock.new
    mock.expect :call, nil do |event_name, context|
      event_name == "comment_created" &&
      context[:comment][:content] == "Hello World" &&
      context[:creative][:id] == @creative.id
    end

    SystemEvents::Dispatcher.stub :dispatch, mock do
      post creative_comments_path(@creative), params: { comment: { content: "Hello World" } }
    end

    assert_response :created
    mock.verify
  end

  test "does not dispatch comment_created event for private comments" do
    SystemEvents::Dispatcher.stub :dispatch, ->(*args) { raise "Dispatcher should not be called" } do
      post creative_comments_path(@creative), params: { comment: { content: "Private Hello", private: true } }
    end

    assert_response :created
    assert Comment.last.private?
  end
end
