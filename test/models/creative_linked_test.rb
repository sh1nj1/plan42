require "test_helper"

class CreativeLinkedTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(email: "linked-owner@example.com", password: "secret", name: "Owner")
    @shared_user = User.create!(email: "linked-shared@example.com", password: "secret", name: "Shared")
    Current.session = Struct.new(:user).new(@owner)
    @parent = Creative.create!(user: @owner, description: "Parent")
    @creative = Creative.create!(user: @owner, parent: @parent, description: "Original", progress: 1.0)
  end

  teardown do
    Current.reset
  end

  test "does not create duplicate shares for linked creatives" do
    CreativeShare.create!(creative: @creative, user: @shared_user, permission: :read)

    assert_raises(ActiveRecord::RecordInvalid) do
      CreativeShare.create!(creative: @creative, user: @shared_user, permission: :read)
    end
  end

  test "updates progress when changed" do
    @creative.update!(progress: 0.3)
    assert_equal 0.3, @creative.reload.progress
  end

  test "destroys linked creatives when origin deleted" do
    CreativeShare.create!(creative: @creative, user: @shared_user, permission: :read)
    @creative.create_linked_creative_for_user(@shared_user)

    linked = Creative.find_by(origin_id: @creative.id, user_id: @shared_user.id)
    assert_not_nil linked

    assert_nothing_raised { @creative.destroy }
    assert_empty Creative.where(origin_id: @creative.id)
  end

  test "checks permissions for owners and shared users" do
    CreativeShare.create!(creative: @creative, user: @shared_user, permission: :read)
    @creative.create_linked_creative_for_user(@shared_user)

    assert @creative.has_permission?(@owner)
    assert @creative.has_permission?(@shared_user)

    other_user = User.create!(email: "linked-other@example.com", password: "secret", name: "Other")
    refute @creative.has_permission?(other_user)
  end
end
