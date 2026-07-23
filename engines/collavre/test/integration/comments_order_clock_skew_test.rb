require "test_helper"

# Regression test for chat message ordering under cross-process clock skew.
#
# A user message is stamped with created_at by the web request process, while
# the agent reply placeholder is stamped by a background worker/agent process.
# When those clocks are skewed, the agent reply can carry a created_at that is
# EARLIER than the user message that triggered it, even though it was inserted
# later (and therefore has a HIGHER id). Ordering the timeline by created_at
# then renders the reply above the user message. The id sequence is the true
# causal insertion order, so the timeline must order by id.
class CommentsOrderClockSkewTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "skew-user@example.com", password: TEST_PASSWORD, name: "SkewUser")
    @creative = Creative.create!(user: @user, description: "Skew creative")

    # An earlier comment used as the pagination anchor (after_id) below. Lowest id.
    @anchor = @creative.comments.create!(user: @user, content: "ANCHOR_MESSAGE")

    # Inserted first -> lower id. This is the user message.
    @user_message = @creative.comments.create!(user: @user, content: "FIRST_USER_MESSAGE")

    # Inserted second -> higher id. This is the agent reply, but its created_at
    # is backdated 2s (simulating a lagging worker clock) to before the user
    # message. update_column bypasses callbacks/validations and touches only
    # created_at, mimicking a persisted row stamped by a skewed clock.
    @agent_reply = @creative.comments.create!(user: @user, content: "SECOND_AGENT_REPLY")
    @agent_reply.update_column(:created_at, @user_message.created_at - 2.seconds)
  end

  test "timeline orders by insertion (id) despite backdated agent reply created_at" do
    assert @agent_reply.id > @user_message.id, "agent reply must have the higher id"
    assert @agent_reply.created_at < @user_message.created_at, "agent reply created_at must be backdated"

    sign_in_as(@user)
    get creative_comments_path(@creative)
    assert_response :success

    user_pos = response.body.index("FIRST_USER_MESSAGE")
    agent_pos = response.body.index("SECOND_AGENT_REPLY")

    assert user_pos, "user message must be rendered"
    assert agent_pos, "agent reply must be rendered"
    assert user_pos < agent_pos,
      "user message must render before the agent reply it triggered (id order), " \
      "not after it due to a backdated created_at"
  end

  test "after_id pagination orders by insertion (id) despite backdated agent reply created_at" do
    sign_in_as(@user)
    # Load the page above the anchor: returns the user message and its agent reply.
    get creative_comments_path(@creative, after_id: @anchor.id)
    assert_response :success

    user_pos = response.body.index("FIRST_USER_MESSAGE")
    agent_pos = response.body.index("SECOND_AGENT_REPLY")

    assert user_pos, "user message must be rendered in the after_id page"
    assert agent_pos, "agent reply must be rendered in the after_id page"
    assert user_pos < agent_pos,
      "after_id paging must also order by id, so the user message renders before " \
      "the agent reply despite the backdated created_at"
  end
end
