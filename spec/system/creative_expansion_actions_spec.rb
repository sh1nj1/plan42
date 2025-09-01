require 'rails_helper'

RSpec.describe 'Creative expansion actions', type: :system, js: true do
  let!(:user) { User.create!(email: 'user@example.com', password: 'password', name: 'User', email_verified_at: Time.current) }
  let!(:root_creative) { Creative.create!(description: 'Root', user: user) }
  let!(:child) { Creative.create!(description: 'Child', user: user, parent: root_creative) }

  def resize_window_to_pc
    page.current_window.resize_to(1200, 800)
  rescue Capybara::NotSupportedByDriverError
  end

  before do
    driven_by(:selenium, using: :headless_chrome)
    resize_window_to_pc
    visit new_session_path
    fill_in placeholder: I18n.t('users.new.enter_your_email'), with: user.email
    fill_in placeholder: I18n.t('users.new.enter_your_password'), with: 'password'
    find('#sign-in-submit').click
  end

  it 'binds edit and comment buttons for loaded children' do
    visit creative_path(root_creative)
    find("#creative-#{root_creative.id} .creative-toggle-btn").click
    expect(page).to have_css("#creative-#{child.id} .edit-inline-btn")

    find("#creative-#{child.id} .edit-inline-btn").click
    expect(page).to have_css('#inline-edit-form-element', visible: :visible)
    find('#inline-close').click

    find("#creative-#{child.id} [name='show-comments-btn']").click
    expect(page).to have_css('#comments-popup', visible: :visible)
  end

  it 'binds edit and comment buttons after using expand all' do
    visit creative_path(root_creative)
    find('#expand-all-btn').click
    expect(page).to have_css("#creative-#{child.id} .edit-inline-btn")

    find("#creative-#{child.id} .edit-inline-btn").click
    expect(page).to have_css('#inline-edit-form-element', visible: :visible)
    find('#inline-close').click

    find("#creative-#{child.id} [name='show-comments-btn']").click
    expect(page).to have_css('#comments-popup', visible: :visible)
  end
  it 'sends current creative id when toggling expansion' do
    visit creative_path(root_creative)
    find("#creative-#{root_creative.id} .creative-toggle-btn").click
    find("#creative-#{root_creative.id} .creative-toggle-btn").click
    state = CreativeExpandedState.find_by(user: user, creative: root_creative)
    expect(state).not_to be_nil
    expect(state.expanded_status).to include(root_creative.id.to_s => false)
  end
end
