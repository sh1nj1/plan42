require_relative "../application_system_test_case"

class OnboardingGuideTest < ApplicationSystemTestCase
  test "first sign in teaches progress and deleting the guide completes onboarding" do
    user = User.create!(
      email: "onboarding-system@example.com",
      name: "Onboarding System User",
      password: SystemHelpers::PASSWORD,
      password_confirmation: SystemHelpers::PASSWORD,
      email_verified_at: Time.current,
      locale: "en"
    )

    resize_window_to(1440, 900)
    using_wait_time(10) { sign_in_via_ui(user) }

    guide = Creative.onboarding_guides.find_by!(user: user)
    progress_card = guide.children.find { |child| child.onboarding_metadata["step_key"] == "progress_rollup" }
    progress_step = progress_card.children.sole
    assert_selector ".creative-workspace-tree-link[data-creative-id='#{guide.id}']", wait: 10
    assert_selector ".feature-card--onboarding[data-key]", count: 3, wait: 10
    assert_equal "0px", page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector('.feature-card--onboarding[data-key]')).borderTopWidth
    JS
    within ".feature-card[data-key='progress_rollup']" do
      click_link I18n.t("collavre.onboarding.actions.progress_rollup", locale: :en)
    end
    assert_selector "creative-tree-row[creative-id='#{progress_step.id}']", wait: 10

    progress_selector = "creative-tree-row[creative-id='#{progress_step.id}'] [data-progress-toggle]"
    assert_selector "#{progress_selector}.onboarding-progress-highlight", wait: 10
    find(progress_selector).click
    assert_no_selector "#{progress_selector}.progress-toggle-saving", wait: 10
    assert_selector "#{progress_selector} .progress-toggle-checkbox:checked", visible: :all, wait: 10
    assert_equal 1.0, progress_step.reload.progress
    assert_operator guide.reload.progress, :>, 0.0

    delete_path = collavre.creative_path(guide, delete_with_children: true)
    delete_status = page.driver.browser.execute_async_script(<<~JS, delete_path)
      const path = arguments[0];
      const done = arguments[1];
      fetch(window.location.href, { method: 'HEAD' })
        .then((response) => response.headers.get('X-CSRF-Token'))
        .then((token) => fetch(path, { method: 'DELETE', headers: { 'X-CSRF-Token': token } }))
        .then((response) => done(response.status));
    JS
    assert_equal 204, delete_status

    assert_not Creative.exists?(guide.id)
    assert_not_nil user.reload.onboarding_completed_at

    visit collavre.creatives_path
    assert_no_selector ".creative-workspace-tree-link[data-creative-id='#{guide.id}']", wait: 10
    assert_empty Creative.onboarding_guides.where(user: user)
  end
end
