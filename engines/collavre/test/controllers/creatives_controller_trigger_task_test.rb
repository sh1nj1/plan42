# frozen_string_literal: true

require "test_helper"

class CreativesControllerTriggerTaskTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user, password: "password")

    @trigger_parent = Collavre::Creative.create!(
      user: @user,
      description: "Trigger Container",
      data: { "trigger" => { "on_child_enter" => true } }
    )
    @normal_parent = Collavre::Creative.create!(
      user: @user,
      description: "Normal Parent"
    )
  end

  test "show JSON returns is_trigger_task true for child of trigger container" do
    child = Collavre::Creative.create!(
      user: @user,
      parent: @trigger_parent,
      description: "Trigger Task Child"
    )

    get creative_path(child), headers: { "ACCEPT" => "application/json" }
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal true, json["is_trigger_task"]
  end

  test "show JSON returns is_trigger_task true even without loop state" do
    child = Collavre::Creative.create!(
      user: @user,
      parent: @trigger_parent,
      description: "New Trigger Task"
    )

    get creative_path(child), headers: { "ACCEPT" => "application/json" }
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal true, json["is_trigger_task"]
    assert_nil json["trigger_loop"]
  end

  test "show JSON returns is_trigger_task false for child of normal parent" do
    child = Collavre::Creative.create!(
      user: @user,
      parent: @normal_parent,
      description: "Normal Child"
    )

    get creative_path(child), headers: { "ACCEPT" => "application/json" }
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal false, json["is_trigger_task"]
  end

  test "show JSON returns is_trigger_task false for root creative" do
    get creative_path(@trigger_parent), headers: { "ACCEPT" => "application/json" }
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal false, json["is_trigger_task"]
  end

  test "show JSON returns is_trigger_task true with existing loop state" do
    child = Collavre::Creative.create!(
      user: @user,
      parent: @trigger_parent,
      description: "Running Task",
      data: { "trigger" => { "loop" => { "state" => "running", "current_iteration" => 3, "max_iterations" => 10 } } }
    )

    get creative_path(child), headers: { "ACCEPT" => "application/json" }
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal true, json["is_trigger_task"]
    assert_equal "running", json["trigger_loop"]["state"]
  end
end
