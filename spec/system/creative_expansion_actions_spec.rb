require 'rails_helper'

RSpec.describe 'Creative expansion actions', type: :system, js: true do
  let!(:user) { User.create!(email: 'user@example.com', password: SystemHelpers::PASSWORD, name: 'User', email_verified_at: Time.current, notifications_enabled: false) }
  let!(:root_creative) { Creative.create!(description: 'Root', user: user) }
  let!(:child) { Creative.create!(description: 'Child', user: user, parent: root_creative) }

  def row_selector(creative)
    "creative-tree-row[dom-id='creative-#{creative.id}']"
  end

  def resize_window_to_pc
    page.current_window.resize_to(1200, 800)
  rescue Capybara::NotSupportedByDriverError
  end

  before do
    resize_window_to_pc
    sign_in(user)
    visit creatives_path
  end

  it 'binds edit and comment buttons for loaded children' do
    find(row_selector(root_creative)).hover
    sleep(1)
    find("#{row_selector(root_creative)} .creative-toggle-btn").click

    child_row = find(row_selector(child), visible: :visible)
    child_row.find('.creative-row').hover
    within(child_row) do
      expect(page).to have_css('.edit-inline-btn', visible: :visible)
      find('.edit-inline-btn').click
    end

    expect(page).to have_css('#inline-edit-form-element', visible: :visible)
    find('#inline-close').click

    child_row.find('.creative-row').hover
    within(child_row) do
      find("[name='show-comments-btn']").click
    end
    expect(page).to have_css('#comments-popup', visible: :visible)
  end

  it 'binds edit and comment buttons after using expand all' do
    find('#expand-all-btn').click
    child_row = find(row_selector(child), visible: :visible)
    child_row.find('.creative-row').hover
    within(child_row) do
      find("[name='show-comments-btn']").click
    end
    expect(page).to have_css('#comments-popup', visible: :visible)

    expect(page).to have_css("#{row_selector(child)} .edit-inline-btn")
    within(child_row) do
      find('.edit-inline-btn').click
    end

    expect(page).to have_css('#inline-edit-form-element', visible: :visible)
    find('#inline-close').click
  end

  it 'resets expand all state after navigation' do
    find('#expand-all-btn').click
    expect(page).to have_css(row_selector(child))

    visit root_path
    visit creatives_path
    expect(page).not_to have_css(row_selector(child))
  end
  it 'sends current creative id when toggling expansion' do
    find(row_selector(root_creative)).hover
    find("#{row_selector(root_creative)} .creative-toggle-btn").click
    find(row_selector(root_creative)).hover
    find("#{row_selector(root_creative)} .creative-toggle-btn").click
    state = CreativeExpandedState.find_by(user: user, creative: root_creative)
    expect(state).to be_nil
  end
end
