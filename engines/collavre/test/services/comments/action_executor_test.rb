require "test_helper"
require "json"

class Comments::ActionExecutorTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @approver = users(:two)
    @creative = creatives(:tshirt)
  end

  test "marks execution metadata and preserves action history" do
    action_payload = {
      "action" => "update_creative",
      "attributes" => { "progress" => 0.5 }
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @user
    )

    Comments::ActionExecutor.new(comment: comment, executor: @user).call

    comment.reload
    assert_equal action_payload, JSON.parse(comment.action)
    assert_equal @user.id, comment.approver.id
    assert_not_nil comment.action_executed_at
    assert_equal @user.id, comment.action_executed_by.id
    assert_in_delta 0.5, comment.creative.reload.progress
  end

  test "resets execution metadata when action fails" do
    action_payload = {
      "action" => "update_creative",
      "attributes" => { "progress" => 2.0 }
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @user
    )

    executor = Comments::ActionExecutor.new(comment: comment, executor: @user)

    error = assert_raises(Comments::ActionExecutor::ExecutionError) do
      executor.call
    end
    assert_match "less than or equal to 1.0", error.message

    comment.reload
    assert_nil comment.action_executed_at
    assert_nil comment.action_executed_by
  end

  test "creates a child creative using the approval action" do
    action_payload = {
      "action" => "create_creative",
      "attributes" => {
        "description" => "New idea",
        "progress" => 0.25
      }
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @user
    )

    executor = Comments::ActionExecutor.new(comment: comment, executor: @user)
    assert_difference -> { @creative.reload.children.count }, 1 do
      executor.call
    end

    child = @creative.reload.children.order(:created_at).last
    assert_equal "New idea", ActionController::Base.helpers.strip_tags(child.description).strip
    assert_in_delta 0.25, child.progress
    assert_equal @creative.user.id, child.user.id
    assert_nil executor.onboarding_card
    assert_nil executor.onboarding_created_creative
  end

  test "credits onboarding create and update actions to the human executor" do
    @user.update!(onboarding_seeded_at: nil, onboarding_completed_at: nil)
    Creative.inbox_for(@user)
    guide = Collavre::Onboarding::Seeder.call(user: @user)
    card = guide.children.find { |creative| creative.onboarding_metadata["step_key"] == "create_edit" }
    agent = users(:ai_bot)

    create_comment = card.comments.create!(
      content: "Create a practice Creative",
      user: agent,
      action: JSON.generate(
        "action" => "create_creative",
        "attributes" => { "description" => "First draft" }
      ),
      approver: @user,
      skip_dispatch: true
    )

    executor = Comments::ActionExecutor.new(comment: create_comment, executor: @user)
    executor.call

    practice = Creative.find(card.reload.onboarding_metadata["target_creative_id"])
    assert_equal "in_progress", card.onboarding_metadata["status"]
    assert_equal "practice", practice.onboarding_metadata["role"]
    assert_equal card, executor.onboarding_card
    assert_equal practice, executor.onboarding_created_creative
    assert_equal [ card ], executor.onboarding_cards
    assert_equal [ practice ], executor.onboarding_created_creatives
    assert_equal [ card ], executor.onboarding_created_cards

    update_comment = practice.comments.create!(
      content: "Revise the practice Creative",
      user: agent,
      action: JSON.generate(
        "action" => "update_creative",
        "attributes" => { "description" => "Revised draft" }
      ),
      approver: @user,
      skip_dispatch: true
    )

    Comments::ActionExecutor.new(comment: update_comment, executor: @user).call

    assert_equal "completed", card.reload.onboarding_metadata["status"]
    assert_in_delta 1.0, practice.reload.progress
  end

  test "delete action uses onboarding completion cleanup" do
    @user.update!(onboarding_seeded_at: nil, onboarding_completed_at: nil)
    Creative.inbox_for(@user)
    guide = Collavre::Onboarding::Seeder.call(user: @user)
    session_id = guide.onboarding_metadata["session_id"]
    wrapper = Creative.create!(user: @user, description: "Wrapper")
    guide.update!(parent: wrapper)
    comment = wrapper.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate("action" => "delete_creative", "creative_id" => guide.id),
      approver: @user
    )

    Comments::ActionExecutor.new(comment: comment, executor: @user).call

    remaining = Creative.where(user: @user).select do |creative|
      creative.onboarding_metadata&.dig("session_id") == session_id
    end
    assert_empty remaining
    assert_not_nil @user.reload.onboarding_completed_at
  end

  test "delete action rejects session-wide onboarding cleanup without admin permission" do
    @user.update!(onboarding_seeded_at: nil, onboarding_completed_at: nil)
    Creative.inbox_for(@user)
    guide = Collavre::Onboarding::Seeder.call(user: @user)
    perform_enqueued_jobs do
      CreativeShare.create!(creative: guide, user: @approver, permission: :write, shared_by: @user)
    end
    comment = guide.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate("action" => "delete_creative", "creative_id" => guide.id),
      approver: @approver
    )

    error = assert_raises(Comments::ActionExecutor::ExecutionError) do
      Comments::ActionExecutor.new(comment: comment, executor: @approver).call
    end

    assert_equal I18n.t("collavre.comments.approve_no_admin_permission"), error.message
    assert Creative.exists?(guide.id)
  end

  test "supports multiple actions within a single payload" do
    child = Creative.create!(user: @user, parent: @creative, description: "Child", progress: 0.2)

    action_payload = {
      "actions" => [
        {
          "action" => "update_creative",
          "creative_id" => child.id,
          "attributes" => { "progress" => 1.0 }
        },
        {
          "action" => "create_creative",
          "parent_id" => @creative.id,
          "attributes" => { "description" => "Follow up" }
        }
      ]
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @approver
    )

    Comments::ActionExecutor.new(comment: comment, executor: @approver).call

    child.reload
    assert_in_delta 1.0, child.progress
    new_child = @creative.children.order(:created_at).last
    assert_equal "Follow up", ActionController::Base.helpers.strip_tags(new_child.description).strip
    assert_equal @creative, new_child.parent
  end

  test "rolls back all actions when one fails" do
    child = Creative.create!(user: @user, parent: @creative, description: "Child", progress: 0.2)

    action_payload = {
      "actions" => [
        {
          "action" => "update_creative",
          "creative_id" => child.id,
          "attributes" => { "progress" => 0.9 }
        },
        {
          "action" => "update_creative",
          "creative_id" => child.id,
          "attributes" => { "progress" => 2.0 }
        }
      ]
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @approver
    )

    executor = Comments::ActionExecutor.new(comment: comment, executor: @approver)

    error = assert_raises(Comments::ActionExecutor::ExecutionError) do
      executor.call
    end
    assert_match "less than or equal to 1.0", error.message

    child.reload
    assert_in_delta 0.2, child.progress
  end

  test "raises when action targets creative outside the comment tree" do
    external = Creative.create!(user: @user, description: "External")

    action_payload = {
      "action" => "update_creative",
      "creative_id" => external.id,
      "attributes" => { "progress" => 0.5 }
    }

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @user
    )

    executor = Comments::ActionExecutor.new(comment: comment, executor: @user)

    error = assert_raises(Comments::ActionExecutor::ExecutionError) do
      executor.call
    end

    assert_equal I18n.t("collavre.comments.approve_invalid_creative"), error.message
  end

  test "rejects actions outside the linked creative subtree" do
    root = Creative.create!(user: @user, description: "Root")
    linked = Creative.create!(user: @user, parent: root, description: "Linked")
    sibling = Creative.create!(user: @user, parent: root, description: "Sibling")

    action_payload = {
      "action" => "update_creative",
      "creative_id" => sibling.id,
      "attributes" => { "progress" => 0.5 }
    }

    comment = linked.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate(action_payload),
      approver: @user
    )

    executor = Comments::ActionExecutor.new(comment: comment, executor: @user)

    error = assert_raises(Comments::ActionExecutor::ExecutionError) do
      executor.call
    end

    assert_equal I18n.t("collavre.comments.approve_invalid_creative"), error.message
  end

  test "raises when executor no longer matches approver" do
    approver = users(:two)

    comment = @creative.comments.create!(
      content: "Needs approval",
      user: @user,
      action: JSON.generate("action" => "update_creative", "attributes" => { "progress" => 0.5 }),
      approver: @user
    )

    stale_comment = Comment.find(comment.id)
    comment.update!(approver: approver)

    executor = Comments::ActionExecutor.new(comment: stale_comment, executor: @user)

    error = assert_raises(Comments::ActionExecutor::ExecutionError) do
      executor.call
    end

    assert_equal I18n.t("collavre.comments.approve_not_allowed"), error.message
    comment.reload
    assert_nil comment.action_executed_at
    assert_nil comment.action_executed_by
  end
end
