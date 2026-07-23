require "test_helper"

class CommentsControllerOrderingTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
    @user.update!(email_verified_at: Time.current)
    post session_path, params: { email: @user.email, password: "password" }
  end

  # Regression: an agent reply placeholder is stamped with created_at by a
  # background worker whose clock can lag the web process that stamped the
  # triggering user message. The reply then persists with a HIGHER id but an
  # EARLIER created_at. Chat ordering must follow insert order (id), not
  # wall-clock, so the user message always renders before the reply it
  # triggered. A created_at sort (even with an id tiebreaker) reverses them
  # because the timestamps genuinely differ.
  test "orders comments by id when created_at is skewed backwards" do
    user_msg = @creative.comments.create!(content: "my message", user: @user)
    reply = @creative.comments.create!(content: "agent reply", user: @user)
    # Simulate cross-process clock skew: reply is inserted after (higher id)
    # yet stamped two seconds earlier than the user message it answers.
    reply.update_column(:created_at, user_msg.created_at - 2.seconds)

    get creative_comments_path(@creative)
    assert_response :success

    user_pos = @response.body.index("id=\"#{ActionView::RecordIdentifier.dom_id(user_msg)}\"")
    reply_pos = @response.body.index("id=\"#{ActionView::RecordIdentifier.dom_id(reply)}\"")

    assert user_pos, "user message should render"
    assert reply_pos, "reply should render"
    assert user_pos < reply_pos,
           "user message (id #{user_msg.id}) must render before its reply " \
           "(id #{reply.id}) despite the reply's earlier created_at"
  end

  # after_id pagination (scrolling down for newer messages) must also follow id
  # order, not created_at, or a skewed reply leaks in out of position.
  test "after_id pagination orders newer messages by id under skew" do
    anchor = @creative.comments.create!(content: "anchor", user: @user)
    first = @creative.comments.create!(content: "first newer", user: @user)
    second = @creative.comments.create!(content: "second newer", user: @user)
    # second has the higher id but a backdated created_at.
    second.update_column(:created_at, first.created_at - 2.seconds)

    get creative_comments_path(@creative, after_id: anchor.id)
    assert_response :success

    first_pos = @response.body.index("id=\"#{ActionView::RecordIdentifier.dom_id(first)}\"")
    second_pos = @response.body.index("id=\"#{ActionView::RecordIdentifier.dom_id(second)}\"")

    assert first_pos, "first newer message should render"
    assert second_pos, "second newer message should render"
    assert first_pos < second_pos,
           "newer messages must render in id order despite skewed created_at"
  end
end
