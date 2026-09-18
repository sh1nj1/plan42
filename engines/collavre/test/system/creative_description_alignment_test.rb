require_relative "../application_system_test_case"

class CreativeDescriptionAlignmentTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(email: "description-alignment@example.com", password: SystemHelpers::PASSWORD,
                         name: "Alignment User", email_verified_at: Time.current, notifications_enabled: false)
    @heading = Creative.create!(user: @user, description: "A long creative heading " * 8)
    parent = @heading
    3.times do |index|
      parent = Creative.create!(user: @user, parent: parent, description: "Slide level #{index + 2} " * 20)
    end
    markdown = (1..6).map { |level| "#{'#' * level} #{'A long nested heading ' * 8}\n\n#{'A long body paragraph. ' * 20}" }.join("\n\n")
    parent.update!(content_type_input: "markdown", markdown_source: markdown)
    @body = Creative.create!(user: @user, content_type_input: "markdown", markdown_source: markdown)
    Creative.rebuild!
    sign_in_via_ui(@user)
  end

  [ 1200, 390 ].each do |width|
    test "profile preference controls body alignment while preserving headings at #{width}px" do
      resize_window_to(width, 800)

      [ true, false, true ].each do |enabled|
        set_alignment_preference(enabled)
        assert_tree_alignment(enabled)
        assert_slide_alignment(enabled)
      end
    end
  end

  private

  def set_alignment_preference(enabled)
    visit collavre.user_path(@user)
    find("#user_justify_creative_descriptions").set(enabled)
    click_button I18n.t("collavre.users.update_profile")
    assert_text I18n.t("collavre.users.profile_updated")
    assert_selector "input#user_justify_creative_descriptions#{enabled ? ':checked' : ':not(:checked)'}"
    assert_equal enabled, @user.reload.justify_creative_descriptions?
  end

  def assert_tree_alignment(enabled)
    visit collavre.creatives_path
    assert_alignment "#creative-#{@heading.id} h1 .creative-content", enabled ? "left" : "start"
    assert_alignment "#creative-#{@body.id} .creative-content", enabled ? "justify" : "start"
    assert_nested_alignment "#creative-#{@body.id} .creative-content", enabled
  end

  def assert_slide_alignment(enabled)
    visit collavre.slide_view_creative_path(@heading)
    (1..3).each do |level|
      assert_alignment "#slide-content h#{level}.creative-content", enabled ? "left" : "start"
      find("body").send_keys(:arrow_right)
    end
    assert_alignment "#slide-content div.creative-content", enabled ? "justify" : "start"
    assert_nested_alignment "#slide-content div.creative-content", enabled
  end

  def assert_nested_alignment(selector, enabled)
    (1..6).each do |level|
      assert_alignment "#{selector} h#{level}", enabled ? "left" : "start"
    end
    assert_alignment "#{selector} p", enabled ? "justify" : "start"
  end

  def assert_alignment(selector, expected)
    assert_selector selector, style: { "text-align" => expected }
  end
end
