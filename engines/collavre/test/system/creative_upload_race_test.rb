require_relative "../application_system_test_case"

class CreativeUploadRaceTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "user@example.com",
      password: SystemHelpers::PASSWORD,
      name: "User",
      email_verified_at: Time.current,
      notifications_enabled: false
    )
    @creative1 = Creative.create!(description: "Creative 1", user: @user)
    @creative2 = Creative.create!(description: "Creative 2", user: @user)

    resize_window_to
    sign_in_via_ui(@user)
    visit collavre.creatives_path
  end

  def open_inline_editor(creative)
    find("#creative-#{creative.id}").hover
    find("#creative-#{creative.id} .edit-inline-btn", wait: 5).click
    assert_selector "#inline-edit-form-element", wait: 5
  end

  test "navigation waits for pending uploads" do
    open_inline_editor(@creative1)

    # Simulate pending upload
    execute_script("window.creativeRowEditor.setUploadsPending(true)")

    # Type something to make it dirty
    find(".lexical-content-editable").send_keys(" with upload")

    # Trigger navigation (Arrow Down)
    # We use send_keys on the editor to trigger handleEditorKeyDown
    find(".lexical-content-editable").send_keys(:arrow_down)

    # Verify we are STILL on creative 1 (navigation blocked)
    # The form should still be attached to creative 1's row or at least visible there
    # And creative 2 should NOT be active yet

    # Check that creative 2 is NOT active (no template attached)
    # The template is attached when move() proceeds
    # We can check if the form's dataset.creativeId is still @creative1.id

    # Wait a bit to ensure async move would have happened if it wasn't blocked
    sleep 0.5

    current_id = execute_script("return document.getElementById('inline-edit-form-element').dataset.creativeId")
    assert_equal @creative1.id.to_s, current_id, "Should still be on Creative 1 while upload is pending"

    # Resolve upload
    execute_script("window.creativeRowEditor.resolveUploadCompletion()")

    # Now navigation should proceed
    # Wait for form to move to creative 2

    # We need to wait for the async move to complete
    # Since we can't easily await the promise from here, we wait for the UI update

    # Verify form moves to creative 2
    # This might take a moment as the async function resumes

    # Retry checking for a few seconds
    Timeout.timeout(5) do
      loop do
        current_id = execute_script("return document.getElementById('inline-edit-form-element').dataset.creativeId")
        break if current_id == @creative2.id.to_s
        sleep 0.1
      end
    end

    current_id = execute_script("return document.getElementById('inline-edit-form-element').dataset.creativeId")
    assert_equal @creative2.id.to_s, current_id, "Should have moved to Creative 2 after upload resolved"
  end
end
