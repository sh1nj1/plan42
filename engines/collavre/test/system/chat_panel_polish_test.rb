require_relative "../application_system_test_case"

class ChatPanelPolishTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(email: "chat-polish@example.com", password: SystemHelpers::PASSWORD,
      name: "Chat Tester", email_verified_at: Time.current, notifications_enabled: false)
    @creative = Creative.create!(description: "Chat polish", user: @user)
    @topic = @creative.topics.create!(name: "Design", user: @user)
    @comment = @creative.comments.create!(user: @user, topic: @creative.main_topic, content: "Readable chat message", skip_dispatch: true)
    resize_window_to(1400, 900)
    sign_in_via_ui(@user)
    visit collavre.creative_path(@creative, open_comments: true)
    find('#comments-popup [data-comments--popup-target="title"]').click
    assert_docked_comments_loaded
    assert_selector "#comment_#{@comment.id}"
  end

  test "input typography headers and initial avatars are readable" do
    styles = page.evaluate_script(<<~JS)
      (() => {
        const css = s => getComputedStyle(document.querySelector(s));
        const field = document.querySelector('#new-comment-form textarea');
        return { font: css('#new-comment-form textarea').fontFamily,
          formFont: css('#new-comment-form').fontFamily,
          fieldWidth: field.getBoundingClientRect().width,
          formWidth: document.querySelector('#new-comment-form').getBoundingClientRect().width,
          placeholder: getComputedStyle(field, '::placeholder').color,
          muted: css('.comment-header-time').color,
          nameSize: css('.comment-header-name').fontSize, nameWeight: css('.comment-header-name').fontWeight,
          timeSize: css('.comment-header-time').fontSize,
          buttonFont: css('#attach-image-btn').fontFamily, buttonSize: css('#attach-image-btn').fontSize,
          buttonWeight: css('#attach-image-btn').fontWeight };
      })()
    JS
    assert_equal styles['formFont'], styles['font']
    assert_equal styles['font'], styles['buttonFont']
    assert_in_delta styles['formWidth'], styles['fieldWidth'], 1
    assert_equal styles['muted'], styles['placeholder']
    assert_equal '14px', styles['nameSize']
    assert_equal '600', styles['nameWeight']
    assert_equal '11px', styles['timeSize']
    assert_equal '13px', styles['buttonSize']
    assert_equal '500', styles['buttonWeight']
    assert_selector "#comment_#{@comment.id} .comment-user-menu-trigger .avatar-initial", text: "C"
    assert_no_selector "#comment_#{@comment.id} .comment-user-menu-trigger img"
    find("#comment_#{@comment.id} .comment-user-menu-trigger").click
    assert_selector "#comment_#{@comment.id} .comment-user-popup", visible: :visible
    assert_equal 'none', page.evaluate_script("getComputedStyle(document.querySelector('#comment_#{@comment.id} a.popup-menu-item')).textDecorationLine")
    dot = page.evaluate_script("getComputedStyle(document.querySelector('#comment_#{@comment.id} .comment-user-popup-status-dot')).backgroundColor")
    assert_not_equal 'rgba(0, 0, 0, 0)', dot
  end

  test "stop remains visible and readable while other controls are hidden" do
    task = Collavre::Task.create!(name: "Running", agent: @user, status: "running")
    @comment.update!(task: task)
    visit collavre.creative_path(@creative, open_comments: true)
    find('#new-comment-form textarea').click
    selector = "#comment_#{@comment.id} .comment-stop-btn"
    assert_selector selector, visible: :visible
    assert_equal '11px', page.evaluate_script("getComputedStyle(document.querySelector('#{selector}')).fontSize")
    find(selector).hover
    styles = page.evaluate_script("(() => { const s = getComputedStyle(document.querySelector('#{selector}')); return [s.color, s.backgroundColor]; })()")
    assert_not_equal styles[0], styles[1]
  end

  test "touch users retain message actions" do
    page.driver.browser.execute_cdp('Emulation.setTouchEmulationEnabled', enabled: true)
    find('#new-comment-form textarea').click
    assert_equal '1', page.evaluate_script("getComputedStyle(document.querySelector('#comment_#{@comment.id} .copy-comment-link-btn')).opacity")
  ensure
    page.driver.browser.execute_cdp('Emulation.setTouchEmulationEnabled', enabled: false)
  end

  test "fullscreen content is centered and fits mobile" do
    [ 1400, 480 ].each do |width|
      resize_window_to(width, 900)
      visit collavre.creative_path(@creative, open_comments: true)
      assert_selector '#new-comment-form textarea'
      find('.comments-popup-fullscreen').click
      assert_selector '#comments-popup[data-fullscreen="true"]'
      page.execute_script("document.querySelector('#comments-popup').getAnimations().forEach(animation => animation.finish())")
      dimensions = page.evaluate_script(<<~JS)
        ['#comments-list', '#new-comment-form'].map(selector => {
          const rect = document.querySelector(selector).getBoundingClientRect();
          return { width: rect.width, center: rect.x + rect.width / 2, viewport: innerWidth };
        })
      JS
      dimensions.each do |box|
        assert_operator box['width'], :<=, 880
        assert_operator box['width'], :<=, box['viewport']
        assert_in_delta box['viewport'] / 2, box['center'], 1
      end
    end
  end

  test "message actions and archive controls reveal on hover and keyboard focus" do
    skip 'Requires a hovering pointer' unless page.evaluate_script("matchMedia('(hover: hover) and (pointer: fine)').matches")
    find('#new-comment-form textarea').click
    selector = "#comment_#{@comment.id} .copy-comment-link-btn"
    assert_equal '0', page.evaluate_script("getComputedStyle(document.querySelector('#{selector}')).opacity")
    find("#comment_#{@comment.id}").hover
    assert_equal '1', page.evaluate_script("getComputedStyle(document.querySelector('#{selector}')).opacity")
    find('#new-comment-form textarea').hover
    page.execute_script("document.querySelector('#{selector}').focus()")
    assert_equal '1', page.evaluate_script("getComputedStyle(document.querySelector('#{selector}')).opacity")
    chip = ".topic-tag[data-id='#{@topic.id}']"
    assert_selector chip
    find('#new-comment-form textarea').click
    assert_equal '0', page.evaluate_script("getComputedStyle(document.querySelector(\"#{chip} .archive-topic-btn\")).opacity")
    find(chip).hover
    assert_not_equal '0', page.evaluate_script("getComputedStyle(document.querySelector(\"#{chip} .archive-topic-btn\")).opacity")
  end
end
