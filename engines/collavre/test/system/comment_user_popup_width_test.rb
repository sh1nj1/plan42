require_relative "../application_system_test_case"

class CommentUserPopupWidthTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "popup-width@example.com",
      password: SystemHelpers::PASSWORD,
      name: "PopupWidthUser",
      email_verified_at: Time.current,
      notifications_enabled: false
    )
    @creative = Creative.create!(description: "Root", user: @user)

    resize_window_to
    sign_in_via_ui(@user)
  end

  test "avatar model and effort editor keeps the original compact width" do
    agent = users(:ai_bot)
    gateway = Collavre::AgentGateway.create!(owner: @user, name: "Popup layout",
      base_url: "https://proxy.example.com", admin_key: "admin", completion_key: "completion")
    agent.update!(created_by_id: @user.id, llm_vendor: "cli_proxy", agent_gateway: gateway,
      llm_model: "paperclip/codex_local/a-very-long-model-name-for-layout", reasoning_effort: "high")
    comment = @creative.comments.create!(user: agent, topic_id: @creative.main_topic.id, content: "Hello", skip_dispatch: true)

    [ 1200, 480 ].each do |width|
      resize_window_to(width, 900)
      visit collavre.creative_path(@creative, open_comments: true)
      assert_docked_comments_loaded
      selector = "#comment_#{comment.id} .comment-user-popup"
      assert_selector "#comment_#{comment.id} .comment-user-menu-trigger" do |trigger|
        trigger.click unless page.has_css?("#{selector} input[name=\"user[llm_model]\"]", wait: 0)
        page.has_css?("#{selector} input[name=\"user[llm_model]\"]", wait: 0)
      end
      within(selector) do
        assert_selector "input[name='user[llm_model]']"
        assert_selector "select[name='user[reasoning_effort]']"
      end
      dimensions = page.evaluate_script(<<~JS, selector)
        ((selector) => {
          const menu = document.querySelector(selector);
          const editor = menu.querySelector('.comment-agent-model-editor');
          const form = editor.querySelector('form').getBoundingClientRect();
          return { width: menu.getBoundingClientRect().width,
            scrollWidth: menu.scrollWidth, clientWidth: menu.clientWidth,
            fields: Array.from(editor.querySelectorAll('input[type="text"], select')).map(field => {
              const rect = field.getBoundingClientRect();
              return { left: rect.left, right: rect.right, formLeft: form.left, formRight: form.right };
            }) };
        })(arguments[0])
      JS
      assert_in_delta 240, dimensions["width"], 1
      assert_equal dimensions["clientWidth"], dimensions["scrollWidth"]
      dimensions["fields"].each do |field|
        assert_in_delta field["formLeft"], field["left"], 1
        assert_in_delta field["formRight"], field["right"], 1
      end
    end
  end
end
