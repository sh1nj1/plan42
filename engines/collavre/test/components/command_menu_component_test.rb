require "test_helper"

class CommandMenuComponentTest < ViewComponent::TestCase
  test "renders with default menu_id" do
    render_inline(Collavre::CommandMenuComponent.new)

    assert_selector "#command-menu.common-popup", visible: :all
    assert_selector "#command-menu ul.common-popup-list", visible: :all
  end

  test "renders with custom menu_id" do
    render_inline(Collavre::CommandMenuComponent.new(menu_id: "custom-menu"))

    assert_selector "#custom-menu.common-popup", visible: :all
    assert_selector "#custom-menu ul.common-popup-list", visible: :all
  end

  test "does not include extra CSS classes" do
    component = Collavre::CommandMenuComponent.new
    assert_nil component.extra_classes
    assert_equal "common-popup", component.css_classes
  end

  test "form_submit_label returns i18n translation" do
    component = Collavre::CommandMenuComponent.new
    assert_equal I18n.t("collavre.comments.command_menu.form_submit"), component.form_submit_label
  end

  test "form_cancel_label returns i18n translation" do
    component = Collavre::CommandMenuComponent.new
    assert_equal I18n.t("collavre.comments.command_menu.form_cancel"), component.form_cancel_label
  end
  test "exposes form and more/less labels to the menu script" do
    I18n.with_locale(:ko) do
      render_inline(Collavre::CommandMenuComponent.new)

      assert_selector "#command-menu[data-form-submit='확인'][data-form-cancel='취소']", visible: :all
      assert_selector "#command-menu[data-more-label='더보기'][data-less-label='접기']", visible: :all
    end
  end
end
