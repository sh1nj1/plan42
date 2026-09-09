require "test_helper"

module Collavre
  class CreativesControllerEventSourceTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      Current.session = OpenStruct.new(user: @user)
      @agent = users(:ai_bot)
      @parent = Creative.create!(user: @user, description: "Trigger parent")
      @child = Creative.create!(user: @user, parent: @parent, description: "Trigger child")
      CreativeShare.create!(creative: @parent, user: @agent, permission: :write)
      @child.topics.create!(name: "Drop Trigger", user: @user)
    end

    teardown do
      Current.reset
    end

    test "a trigger restart declares its dispatch source" do
      dispatch_options = nil
      SystemEvents::Dispatcher.stub(:dispatch, lambda { |_event, _payload, **options|
        dispatch_options = options
        []
      }) do
        CreativesController.new.send(:post_restart_trigger, @child)
      end

      assert_equal "trigger_restart", dispatch_options[:source]
    end
  end
end
