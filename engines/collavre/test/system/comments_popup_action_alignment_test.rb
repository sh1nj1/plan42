require_relative "../application_system_test_case"

class CommentsPopupActionAlignmentTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "comments-action-alignment@example.com",
      password: SystemHelpers::PASSWORD,
      name: "CommentsActionAlignmentUser",
      email_verified_at: Time.current,
      notifications_enabled: false
    )
    @creative = Creative.create!(description: "Root", user: @user)

    resize_window_to
    sign_in_via_ui(@user)
  end

  test "close and fullscreen actions share centered dimensions" do
    visit root_path
    assert_selector "#creative-#{@creative.id}", wait: 5
    find("#creative-#{@creative.id}").hover
    within("#creative-#{@creative.id}") { find(".comments-btn").click }
    assert_selector "#comments-popup", visible: :visible, wait: 5

    dimensions = page.evaluate_script(<<~JS)
      (() => {
        const box = (selector) => {
          const rect = document.querySelector(selector).getBoundingClientRect()
          return {
            width: rect.width,
            height: rect.height,
            centerX: rect.left + rect.width / 2,
            centerY: rect.top + rect.height / 2
          }
        }

        return {
          fullscreenButton: box('.comments-popup-fullscreen'),
          closeButton: box('#close-comments-btn'),
          fullscreenIcon: box('[data-comments--popup-target="fullscreenIcon"] svg'),
          closeIcon: box('[data-comments--popup-target="closeIcon"] svg')
        }
      })()
    JS

    assert_equal 24, dimensions.dig("fullscreenButton", "width")
    assert_equal 24, dimensions.dig("fullscreenButton", "height")
    assert_equal 24, dimensions.dig("closeButton", "width")
    assert_equal 24, dimensions.dig("closeButton", "height")
    assert_equal 16, dimensions.dig("fullscreenIcon", "width")
    assert_equal 16, dimensions.dig("fullscreenIcon", "height")
    assert_equal 16, dimensions.dig("closeIcon", "width")
    assert_equal 16, dimensions.dig("closeIcon", "height")
    assert_in_delta dimensions.dig("fullscreenButton", "centerY"), dimensions.dig("closeButton", "centerY"), 0.01
    assert_in_delta dimensions.dig("closeButton", "centerX"), dimensions.dig("closeIcon", "centerX"), 0.01
    assert_in_delta dimensions.dig("closeButton", "centerY"), dimensions.dig("closeIcon", "centerY"), 0.01
  end

  test "approval reason is stacked and fills the message width" do
    task = Collavre::Task.create!(name: "Approval", status: "pending_approval", agent: users(:ai_bot),
      creative: @creative, topic_id: @creative.main_topic.id,
      pending_tool_call: { kind: "approval_gate", tool_call_id: "layout-gate" })
    comment = @creative.comments.create!(user: task.agent, approver: @user, topic_id: task.topic_id,
      content: "Proceed?", action: { action: "approval_gate", task_id: task.id, tool_call_id: "layout-gate" }.to_json)

    [ 480, 1000 ].each do |width|
      page.current_window.resize_to(width, 900)
      visit root_path
      find("#creative-#{@creative.id}").hover
      within("#creative-#{@creative.id}") { find(".comments-btn").click }
      assert_selector "#comment_#{comment.id} textarea[data-approval-reason]", visible: :visible
      dimensions = page.evaluate_script(<<~JS)
        (() => {
          const comment = document.getElementById('comment_#{comment.id}')
          const label = comment.querySelector('.comment-approval-reason label').getBoundingClientRect()
          const field = comment.querySelector('[data-approval-reason]').getBoundingClientRect()
          const content = comment.querySelector('.comment-content').getBoundingClientRect()
          return { labelBottom: label.bottom, fieldTop: field.top,
            fieldLeft: field.left, fieldRight: field.right,
            contentLeft: content.left, contentRight: content.right }
        })()
      JS
      assert_operator dimensions['fieldTop'], :>, dimensions['labelBottom']
      assert_in_delta dimensions['contentLeft'], dimensions['fieldLeft'], 1
      assert_in_delta dimensions['contentRight'], dimensions['fieldRight'], 1
    end
  end
end
