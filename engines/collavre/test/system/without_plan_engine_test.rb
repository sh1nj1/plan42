require_relative "../application_system_test_case"

# Integration test: verify collavre core works when CollavrePlan engine is not loaded.
# Temporarily hides the CollavrePlan constant, unregisters navigation items,
# and clears ViewExtensions slots to simulate an environment without the plan engine.
#
# Note: Routes are compiled at boot, so we can't fully unmount the engine mid-test.
# Sign-in must happen BEFORE const removal since removing CollavrePlan breaks
# Rails' lazy route set resolution.
class WithoutPlanEngineTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "no-plan-user@example.com",
      password: SystemHelpers::PASSWORD,
      name: "NoPlanUser",
      email_verified_at: Time.current,
      notifications_enabled: false
    )

    # Sign in BEFORE removing the constant (route helpers need it)
    resize_window_to
    sign_in_via_ui(@user)

    # Save ViewExtensions state before clearing
    @saved_extensions = {}
    %i[creative_toolbar creative_modals navigation_panels].each do |slot|
      @saved_extensions[slot] = Collavre::ViewExtensions.for_slot(slot)
    end

    # Now hide CollavrePlan to simulate it not being loaded
    @original_const = CollavrePlan
    Object.send(:remove_const, :CollavrePlan)

    # Unregister plan navigation items
    @registry = Navigation::Registry.instance
    @registry.unregister(:plans)
    @registry.unregister(:mobile_plans)

    # Clear plan extension slots
    Collavre::ViewExtensions.reset!
  end

  teardown do
    # Restore CollavrePlan constant
    Object.const_set(:CollavrePlan, @original_const) if @original_const

    # Re-register plan navigation items
    @registry&.register(
      key: :mobile_plans,
      label: "app.plans",
      type: :partial,
      partial: "collavre_plan/shared/navigation/mobile_plans_button",
      priority: 100,
      requires_auth: true,
      desktop: false,
      mobile: true
    )
    @registry&.register(
      key: :plans,
      label: "app.plans",
      type: :partial,
      partial: "collavre_plan/shared/navigation/plans_button",
      priority: 120,
      requires_auth: true,
      mobile: false
    )

    # Restore ViewExtensions
    @saved_extensions&.each do |slot, entries|
      entries.each { |entry| Collavre::ViewExtensions.register(slot, **entry) }
    end
  end

  test "creatives page loads without plan engine" do
    visit "/creatives"
    assert_selector "creative-tree-row", minimum: 0, wait: 5

    # Plan-specific UI should not be present
    assert_no_selector ".plans-menu-btn", wait: 1
    assert_no_selector "#plans-timeline-area", wait: 1
    assert_no_selector "[data-controller*='set-plan-modal']", wait: 1
  end

  test "navigation renders without plan buttons" do
    visit "/creatives"

    # Navigation should render without errors
    assert_selector "nav", wait: 5

    # Plan navigation buttons should not be present
    assert_no_selector ".plans-menu-btn", wait: 1
  end

  test "creative with children renders without plan UI" do
    root = Creative.create!(description: "Root Creative", user: @user)
    Creative.create!(description: "Child Creative", user: @user, parent: root)

    visit "/creatives"
    assert_selector "creative-tree-row", minimum: 1, wait: 5

    # Page should not crash — no Plan label rendering errors
    assert_no_text "undefined method"
    assert_no_text "NameError"

    # Set Plan button should not be present
    assert_no_selector ".set-plan-btn", wait: 1
  end
end
