require_relative "../application_system_test_case"

class CreativeMoveMenuSystemTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "creative-move-menu@example.com",
      password: SystemHelpers::PASSWORD,
      name: "Move Menu User",
      email_verified_at: Time.current,
      notifications_enabled: false,
      creative_workspace_enabled: true
    )
    @source = Creative.create!(description: "Menu source", user: @user)
    @destination = Creative.create!(description: "Menu destination", user: @user)
    resize_window_to(1440, 900)
    sign_in_via_ui(@user)
    visit collavre.creatives_path
  end

  test "keyboard moves a creative using the shared destination picker" do
    find("#creative-#{@source.id} [data-creative-move-id]").send_keys(:return)
    find('[data-creative-move-target="destination"]').send_keys(:return)
    input = find('[data-link-creative-target="input"]')
    input.set("Menu destination")
    assert_selector "#link-creative-modal .link-result-item[data-id='#{@destination.id}']"
    input.send_keys(:return)
    find('[data-creative-move-target="confirm"]').send_keys(:return)

    assert_no_selector "dialog[open][data-creative-move-target]"
    assert_selector "#workspace-creative-#{@source.id}[data-parent-id='#{@destination.id}']"
    assert_equal @destination, @source.reload.parent
  end

  test "workspace move menu offers a click-only path" do
    find("#workspace-creative-#{@source.id} [data-creative-move-id]").click
    find('[data-creative-move-target="destination"]').click
    find('[data-link-creative-target="input"]').set("Menu destination")
    find("#link-creative-modal .link-result-item[data-id='#{@destination.id}']").click
    find('[data-creative-move-target="confirm"]').click

    assert_no_selector "dialog[open][data-creative-move-target]"
    assert_selector "#workspace-creative-#{@source.id}[data-parent-id='#{@destination.id}']"
    assert_equal @destination, @source.reload.parent
  end

  test "Escape cancels and returns focus without moving" do
    button = find("#workspace-creative-#{@source.id} [data-creative-move-id]")
    button.send_keys(:return)
    find('[data-creative-move-target="destination"]').send_keys(:escape)

    assert_no_selector "dialog[open][data-creative-move-target]"
    assert_equal @source.id.to_s, page.evaluate_script("document.activeElement.dataset.creativeMoveId")
    assert_nil @source.reload.parent_id
  end

  test "keyboard creates a link from a readable source without the workspace" do
    @user.update!(creative_workspace_enabled: false)
    @source.update!(user: users(:two))
    CreativeShare.create!(creative: @source, user: @user, permission: :read)
    visit collavre.creatives_path(id: @source.id)

    find("#creative-#{@source.id} [data-creative-move-id]").send_keys(:return)
    assert_selector '[data-creative-move-target="mode"] option[value="move"][disabled]', visible: :all
    assert_equal "link", find('[data-creative-move-target="mode"]').value
    find('[data-creative-move-target="destination"]').send_keys(:return)
    input = find('[data-link-creative-target="input"]')
    input.set("Menu destination")
    assert_selector "#link-creative-modal .link-result-item[data-id='#{@destination.id}']"
    input.send_keys(:return)
    find('[data-creative-move-target="confirm"]').send_keys(:return)

    assert_no_selector "dialog[open][data-creative-move-target]"
    assert Creative.exists?(origin_id: @source.id, parent_id: @destination.id, user_id: @user.id)
    assert_nil @source.reload.parent_id
  end
end
