require "test_helper"

class DestroyServiceOnboardingTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @user.update!(onboarding_seeded_at: Time.current, onboarding_completed_at: nil)
  end

  test "records completion after deleting an onboarding guide" do
    guide = Creative.create!(
      user: @user,
      description: "Onboarding",
      data: { "kind" => Creative::ONBOARDING_KIND }
    )

    Collavre::Creatives::DestroyService.new(creative: guide, user: @user, delete_with_children: true).call

    assert_not Creative.exists?(guide.id)
    assert_not_nil @user.reload.onboarding_completed_at
  end

  test "deletes onboarding descendants even when only the guide was requested" do
    guide = Creative.create!(
      user: @user,
      description: "Onboarding",
      data: { "kind" => Creative::ONBOARDING_KIND }
    )
    step = Creative.create!(user: @user, parent: guide, description: "Step")

    Collavre::Creatives::DestroyService.new(creative: guide, user: @user).call

    assert_not Creative.exists?(guide.id)
    assert_not Creative.exists?(step.id)
    assert_not_nil @user.reload.onboarding_completed_at
  end

  test "does not record completion after deleting ordinary content" do
    creative = Creative.create!(user: @user, description: "Ordinary")

    Collavre::Creatives::DestroyService.new(creative: creative, user: @user, delete_with_children: true).call

    assert_nil @user.reload.onboarding_completed_at
  end

  test "deleting any version-two onboarding item cleans the durable session" do
    @user.update!(onboarding_seeded_at: nil)
    Creative.inbox_for(@user)
    guide = Collavre::Onboarding::Seeder.call(user: @user)
    session_id = guide.onboarding_metadata["session_id"]
    practice = guide.descendants.find(&:onboarding_practice?)

    Collavre::Creatives::DestroyService.new(creative: practice, user: @user).call

    remaining = Creative.where(user: @user).select do |creative|
      creative.onboarding_metadata&.dig("session_id") == session_id
    end
    assert_empty remaining
    assert_not_nil @user.reload.onboarding_completed_at
  end

  test "a collaborator without admin permission cannot delete the owner's onboarding session" do
    @user.update!(onboarding_seeded_at: nil)
    Creative.inbox_for(@user)
    guide = Collavre::Onboarding::Seeder.call(user: @user)
    collaborator = users(:two)
    perform_enqueued_jobs do
      CreativeShare.create!(creative: guide, user: collaborator, permission: :write, shared_by: @user)
    end

    result = Collavre::Creatives::DestroyService.new(creative: guide, user: collaborator).call

    assert_not result
    assert Creative.exists?(guide.id)
    assert_nil @user.reload.onboarding_completed_at
  end

  test "recursive deletion cleans an onboarding session below an ordinary ancestor" do
    @user.update!(onboarding_seeded_at: nil)
    Creative.inbox_for(@user)
    guide = Collavre::Onboarding::Seeder.call(user: @user)
    session_id = guide.onboarding_metadata["session_id"]
    practice = guide.descendants.find(&:onboarding_practice?)
    ancestor = Creative.create!(user: @user, description: "Ordinary ancestor")
    outside = Creative.create!(user: @user, description: "Outside container")
    guide.update!(parent: ancestor)
    practice.update!(parent: outside)

    Collavre::Creatives::DestroyService.new(
      creative: ancestor,
      user: @user,
      delete_with_children: true
    ).call

    remaining = Creative.where(user: @user).select do |creative|
      creative.onboarding_metadata&.dig("session_id") == session_id
    end
    assert_empty remaining
    assert_not Creative.exists?(ancestor.id)
    assert Creative.exists?(outside.id)
    assert_not_nil @user.reload.onboarding_completed_at
  end
end
