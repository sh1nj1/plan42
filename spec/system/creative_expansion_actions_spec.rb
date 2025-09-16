require 'rails_helper'

RSpec.describe 'Creative expansion actions', type: :system, js: true do
  let!(:user) { User.create!(email: 'user@example.com', password: SystemHelpers::PASSWORD, name: 'User', email_verified_at: Time.current) }
  let!(:root_creative) { Creative.create!(description: 'Root', user: user) }
  let!(:child) { Creative.create!(description: 'Child', user: user, parent: root_creative) }

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
    find("#creative-#{root_creative.id}").hover
    find("#creative-#{root_creative.id} .creative-toggle-btn").click

    find("#creative-#{child.id}").hover
    expect(page).to have_css("#creative-#{child.id} .edit-inline-btn", visible: :visible)
    find("#creative-#{child.id} .edit-inline-btn").click

    expect(page).to have_css('#inline-edit-form-element', visible: :visible)
    find('#inline-close').click

    find("#creative-#{child.id}").hover
    find("#creative-#{child.id} [name='show-comments-btn']").click
    expect(page).to have_css('#comments-popup', visible: :visible)
  end

  it 'shows the trix toolbar when editing inline' do
    find("#creative-#{root_creative.id}").hover
    find("#creative-#{root_creative.id} .creative-toggle-btn").click

    find("#creative-#{child.id}").hover
    find("#creative-#{child.id} .edit-inline-btn").click

    expect(page).to have_css('#inline-edit-form-element trix-toolbar', visible: :visible)
    within '#inline-edit-form-element trix-toolbar' do
      expect(page).to have_css('button', minimum: 3)
    end

    find('#inline-close').click
  end

  it 'binds edit and comment buttons after using expand all' do
    find('#expand-all-btn').click
    find("#creative-#{child.id}").hover
    find("#creative-#{child.id} [name='show-comments-btn']").click
    expect(page).to have_css('#comments-popup', visible: :visible)

    expect(page).to have_css("#creative-#{child.id} .edit-inline-btn")
    find("#creative-#{child.id} .edit-inline-btn").click

    expect(page).to have_css('#inline-edit-form-element', visible: :visible)
    find('#inline-close').click
  end

  it 'resets expand all state after navigation' do
    find('#expand-all-btn').click
    expect(page).to have_css("#creative-#{child.id}")

    visit root_path
    visit creatives_path
    expect(page).not_to have_css("#creative-#{child.id}")
  end
  it 'sends current creative id when toggling expansion' do
    find("#creative-#{root_creative.id}").hover
    find("#creative-#{root_creative.id} .creative-toggle-btn").click
    find("#creative-#{root_creative.id}").hover
    find("#creative-#{root_creative.id} .creative-toggle-btn").click
    state = CreativeExpandedState.find_by(user: user, creative: root_creative)
    expect(state).to be_nil
  end
end
