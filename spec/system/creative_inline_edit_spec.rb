require 'rails_helper'

RSpec.describe 'Creative inline editing', type: :system, js: true do
  let!(:user) { User.create!(email: 'user@example.com', password: 'password', name: 'User', email_verified_at: Time.current) }
  let!(:root_creative) { Creative.create!(description: 'Root', user: user) }

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

  it 'shows saved row when starting another addition' do
    visit creative_path(root_creative)

    find("#creative-#{root_creative.id} .add-creative-btn").click
    expect(page).not_to have_css("#creative-children-#{root_creative.id} .creative-row")

    fill_in 'inline-creative-description', with: 'First child'
    find('#inline-add').click

    expect(page).to have_css("#creative-children-#{root_creative.id} .creative-row", text: 'First child', count: 1)
    fill_in 'inline-creative-description', with: 'Second child'
    find('#inline-close').click

    expect(page).to have_css("#creative-children-#{root_creative.id} > .creative-tree", count: 2)
    expect(page).to have_css("#creative-children-#{root_creative.id} > .creative-tree:nth-child(1) .creative-row", text: 'First child')
    expect(page).to have_css("#creative-children-#{root_creative.id} > .creative-tree:nth-child(2) .creative-row", text: 'Second child')
    expect(Creative.where(description: 'First child').count).to eq(1)
  end
end
