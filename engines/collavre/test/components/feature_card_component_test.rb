require "test_helper"

class FeatureCardComponentTest < ViewComponent::TestCase
  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
    Current.user = @user
  end

  teardown do
    Current.user = nil
  end

  test "renders the shared card definition on the comment empty surface" do
    card = Collavre::FeatureCardRegistry.find(:mention_agent)

    render_inline(
      Collavre::FeatureCardComponent.new(
        card: card,
        surface: :comment_empty,
        creative: @creative
      )
    )

    assert_selector ".feature-card[data-key='mention_agent']"
    assert_selector ".feature-card-title", text: I18n.t(card.title_key)
    assert_selector "button.feature-card-dismiss[data-action='click->comments--feature-cards#dismiss']"
    assert_no_selector "[data-controller='onboarding-card']"
  end

  test "renders the same definition with an onboarding action" do
    card = Collavre::FeatureCardRegistry.find(:create_edit)
    creative = onboarding_card(step_key: "create_edit", feature_key: "create_edit")

    render_inline(
      Collavre::FeatureCardComponent.new(
        card: card,
        surface: :onboarding,
        creative: creative,
        onboarding_state: creative.onboarding_metadata
      )
    )

    assert_selector ".feature-card[data-key='create_edit'][data-controller='onboarding-card']"
    assert_selector ".feature-card-title", text: I18n.t(card.title_key)
    assert_selector "button.feature-card-action.add-creative-btn"
    assert_no_selector ".feature-card-dismiss"
  end

  test "changes create-edit action to the tracked Creative after it is moved" do
    creative = onboarding_card(
      step_key: "create_edit",
      feature_key: "create_edit",
      status: "in_progress"
    )
    target = Creative.create!(
      user: @user,
      description: "Practice",
      data: {
        "onboarding" => {
          "session_id" => creative.onboarding_metadata["session_id"],
          "role" => "practice",
          "step_key" => "create_edit"
        }
      },
      parent: creative
    )
    data = creative.data.deep_dup
    data["onboarding"]["target_creative_id"] = target.id
    creative.update!(data: data)
    target.update!(parent: creatives(:root_parent))

    render_inline(
      Collavre::FeatureCardComponent.new(
        card: Collavre::FeatureCardRegistry.find(:create_edit),
        surface: :onboarding,
        creative: creative,
        onboarding_state: creative.onboarding_metadata
      )
    )

    expected_path = Collavre::Engine.routes.url_helpers.creatives_path(
      id: target.id,
      onboarding_action: "edit",
      onboarding_target_id: target.id
    )
    assert_selector "a.feature-card-action[href='#{expected_path}']",
                    text: I18n.t("collavre.onboarding.actions.edit_created")
  end

  test "navigates progress action to the tracked Creative after it is moved" do
    creative = onboarding_card(
      step_key: "progress_rollup",
      feature_key: "progress_rollup"
    )
    target = Creative.create!(
      user: @user,
      description: "Practice",
      progress: 0,
      data: {
        "onboarding" => {
          "session_id" => creative.onboarding_metadata["session_id"],
          "role" => "practice",
          "step_key" => "progress_rollup"
        }
      },
      parent: creative
    )
    data = creative.data.deep_dup
    data["onboarding"]["target_creative_id"] = target.id
    creative.update!(data: data)
    target.update!(parent: creatives(:root_parent))

    render_inline(
      Collavre::FeatureCardComponent.new(
        card: Collavre::FeatureCardRegistry.find(:progress_rollup),
        surface: :onboarding,
        creative: creative,
        onboarding_state: creative.onboarding_metadata
      )
    )

    expected_path = Collavre::Engine.routes.url_helpers.creatives_path(
      id: target.id,
      onboarding_action: "progress",
      onboarding_target_id: target.id
    )
    assert_selector "a.feature-card-action[href='#{expected_path}']",
                    text: I18n.t("collavre.onboarding.actions.progress_rollup")
  end

  test "completed onboarding cards render status without another action" do
    creative = onboarding_card(
      step_key: "progress_rollup",
      feature_key: "progress_rollup",
      status: "completed"
    )

    render_inline(
      Collavre::FeatureCardComponent.new(
        card: Collavre::FeatureCardRegistry.find(:progress_rollup),
        surface: :onboarding,
        creative: creative,
        onboarding_state: creative.onboarding_metadata
      )
    )

    assert_selector ".feature-card-status--completed", text: I18n.t("collavre.onboarding.status.completed")
    assert_no_selector ".feature-card-action"
  end

  test "does not render onboarding actions for a non-owner" do
    creative = onboarding_card(step_key: "create_edit", feature_key: "create_edit")
    Current.user = users(:two)

    render_inline(
      Collavre::FeatureCardComponent.new(
        card: Collavre::FeatureCardRegistry.find(:create_edit),
        surface: :onboarding,
        creative: creative,
        onboarding_state: creative.onboarding_metadata
      )
    )

    assert_no_selector ".feature-card-action"
  end

  private

  def onboarding_card(**metadata)
    Creative.create!(
      user: @user,
      description: "Fallback",
      data: {
        "source" => { "type" => Collavre::Creative::ONBOARDING_KIND },
        "onboarding" => {
          "session_id" => SecureRandom.uuid,
          "role" => "card"
        }.merge(metadata.stringify_keys)
      }
    )
  end
end
