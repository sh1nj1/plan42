require "test_helper"
require "ostruct"

class CreativeExpandedStatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
    @user.update!(email_verified_at: Time.current)
    post session_path, params: { email: @user.email, password: "password" }
  end

  test "toggle stores expanded state" do
    post "/creative_expanded_states/toggle", params: { creative_id: @creative.id, node_id: @creative.id, expanded: true }
    assert_response :success
    record = CreativeExpandedState.find_by(creative_id: @creative.id, user_id: @user.id)
    assert_equal({ @creative.id.to_s => true }, record.expanded_status)
  end

  test "toggle removes state when collapsed" do
    CreativeExpandedState.create!(creative_id: @creative.id, user_id: @user.id, expanded_status: { @creative.id.to_s => true })
    post "/creative_expanded_states/toggle", params: { creative_id: @creative.id, node_id: @creative.id, expanded: false }
    assert_response :success
    assert_nil CreativeExpandedState.find_by(creative_id: @creative.id, user_id: @user.id)
  end
end
