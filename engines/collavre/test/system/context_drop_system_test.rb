require_relative "../application_system_test_case"

class ContextDropSystemTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "context-drop@example.com",
      password: SystemHelpers::PASSWORD,
      name: "ContextDropUser",
      email_verified_at: Time.current,
      notifications_enabled: false
    )
    @creative_a = Creative.create!(description: "Creative A", user: @user)
    @creative_b = Creative.create!(description: "Creative B", user: @user)

    resize_window_to
    sign_in_via_ui(@user)
  end

  # NOTE: Uses synthetic DragEvent (dispatchEvent) because Selenium/Capybara
  # cannot perform real HTML5 drag-and-drop. This validates the JS handler logic
  # but cannot catch effectAllowed/dropEffect mismatches that only real drags expose.
  test "user can drop a creative onto the chat context area to add it" do
    visit root_path

    # Wait for creatives to render
    assert_selector "#creative-#{@creative_a.id}", wait: 5
    assert_selector "#creative-#{@creative_b.id}", wait: 5

    # Open chat popup on Creative A by hovering then clicking comments button
    creative_row = find("#creative-#{@creative_a.id}")
    creative_row.hover
    within("#creative-#{@creative_a.id}") do
      find(".comments-btn").click
    end
    assert_selector "#comments-popup", wait: 5

    # The context area exists (may be hidden)
    assert_selector "#comment-contexts", visible: :all, wait: 5

    # Simulate drag-and-drop of Creative B onto the context area
    source = find("#creative-#{@creative_b.id}")
    drag_creative_to_context(source, @creative_b.id)

    # Verify Creative B appears as a context chip
    assert_selector "#comment-contexts .context-chip", text: "Creative B", wait: 10

    # Verify in database
    @creative_a.reload
    assert_includes @creative_a.context_ids, @creative_b.id
  end

  private

  def drag_creative_to_context(source, creative_id)
    page.execute_script(<<~JS, source.native, creative_id.to_s)
      var source = arguments[0],
          creativeId = arguments[1];

      var dt = new DataTransfer();
      var payload = JSON.stringify({ creativeId: creativeId });
      dt.setData('application/x-plan42-creative', payload);
      dt.setData('text/plain', payload);
      var opts = { cancelable: true, bubbles: true, dataTransfer: dt };

      // Find draggable parent
      while (source && !source.draggable) {
        source = source.parentElement;
      }

      // 1. dragstart on source
      source.dispatchEvent(new DragEvent('dragstart', opts));

      // 2. dragover on popup to auto-show context list
      var popup = document.getElementById('comments-popup');
      if (popup) {
        popup.dispatchEvent(new DragEvent('dragover', opts));
      }

      // Wait for context list to become visible, then dispatch on it
      setTimeout(function() {
        var target = document.getElementById('comment-contexts');

        // dragenter on context list
        target.dispatchEvent(new DragEvent('dragenter', opts));

        // dragover on context list (must preventDefault to allow drop)
        var rect = target.getBoundingClientRect();
        var posOpts = Object.assign({
          clientX: rect.left + rect.width / 2,
          clientY: rect.top + rect.height / 2
        }, opts);

        target.dispatchEvent(new DragEvent('dragover', posOpts));

        // drop on context list
        setTimeout(function() {
          target.dispatchEvent(new DragEvent('drop', posOpts));
          source.dispatchEvent(new DragEvent('dragend', opts));
        }, 200);
      }, 300);
    JS

    # Wait for async server call
    sleep 3
  end
end
