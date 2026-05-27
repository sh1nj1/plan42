# frozen_string_literal: true

require "test_helper"

module Collavre
  class ChannelsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @user = users(:one)
      Collavre::Current.user = @user
      @creative = Creative.create!(description: "Test Creative", user: @user)
      @topic = Topic.create!(name: "Channel Topic", creative: @creative, user: @user)
      @channel = Channel.create!(topic: @topic, type: "Collavre::Channel")
      sign_in_as(@user, password: "password")
    end

    test "destroy dismisses an active channel (detaches + sets dismissed_at) and returns 204" do
      delete collavre.channel_path(@channel)
      assert_response :no_content
      @channel.reload
      assert_predicate @channel, :detached?
      assert_predicate @channel, :dismissed?
    end

    test "destroy on a detached (but not yet dismissed) channel dismisses it" do
      @channel.detach!

      delete collavre.channel_path(@channel)
      assert_response :no_content
      assert_predicate @channel.reload, :dismissed?
    end

    test "destroy returns 404 when channel was already dismissed" do
      @channel.dismiss!

      delete collavre.channel_path(@channel)
      assert_response :not_found
    end

    test "destroy returns 404 when channel id does not exist" do
      delete collavre.channel_path(id: 999_999)
      assert_response :not_found
    end

    test "destroy returns 403 when user lacks write permission on creative" do
      other_user = users(:two)
      sign_out
      sign_in_as(other_user, password: "password")

      delete collavre.channel_path(@channel)
      assert_response :forbidden
      assert_predicate @channel.reload, :active?
    end
  end
end
