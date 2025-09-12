require 'rails_helper'

RSpec.describe 'Creative inline editing', type: :system, js: true do
  let!(:user) { User.create!(email: 'user@example.com', password: SystemHelpers::PASSWORD, name: 'User', email_verified_at: Time.current) }
  let!(:root_creative) { Creative.create!(description: 'Root', user: user) }

  def resize_window_to_pc
    page.current_window.resize_to(1200, 800)
  rescue Capybara::NotSupportedByDriverError
  end

  before do
    resize_window_to_pc
    sign_in(user)
    visit creatives_path
  end

  it 'allows editing page title and shows actions' do
    visit creative_path(root_creative)

    find("#creative-#{root_creative.id}").hover
    expect(page).to have_css("#creative-#{root_creative.id} .edit-inline-btn")
    expect(page).to have_css("#creative-#{root_creative.id} .comments-btn")
    expect(page).to have_css("#creative-#{root_creative.id} .creative-progress-incomplete", text: '0%')

    find("#creative-#{root_creative.id} .edit-inline-btn").click
    find('trix-editor[input="inline-creative-description"]').click.set('Updated Title')
    find('#inline-close').click
    wait_for_ajax

    expect(page).to have_css("#creative-#{root_creative.id} .creative-content", text: 'Updated Title')
  end

  it 'shows saved row when starting another addition' do
    find("#creative-#{root_creative.id}").hover
    find("#creative-#{root_creative.id} .edit-inline-btn").click
    find('#inline-add-child').click
    expect(page).not_to have_css("#creative-children-#{root_creative.id} .creative-row")

    find('trix-editor[input="inline-creative-description"]').click.set('First child')
    find('#inline-add').click
    wait_for_ajax

    expect(page).to have_css("#creative-children-#{root_creative.id} .creative-row", text: 'First child', count: 1)
    find('trix-editor[input="inline-creative-description"]').click.set('Second child')
    find('#inline-close').click
    wait_for_ajax

    find("#creative-#{root_creative.id}").hover
    find("#creative-#{root_creative.id} .creative-toggle-btn").click

    expect(page).to have_css("#creative-children-#{root_creative.id} > .creative-tree", count: 2)
    expect(page).to have_css("#creative-children-#{root_creative.id} > .creative-tree:nth-child(1) .creative-row", text: 'First child')
    expect(page).to have_css("#creative-children-#{root_creative.id} > .creative-tree:nth-child(2) .creative-row", text: 'Second child')

    new_creative_id = find("#creative-children-#{root_creative.id} > .creative-tree:nth-child(1)")['data-id']
    new_creative = Creative.find(new_creative_id)
    expect(new_creative.description.body.to_plain_text).to eq('First child')
  end

  it 'supports keyboard shortcuts for add and close' do
    find("#creative-#{root_creative.id}").hover
    find("#creative-#{root_creative.id} .edit-inline-btn").click
    find('trix-editor').send_keys([ :alt, :enter ])

    find('trix-editor[input="inline-creative-description"]').click.set('First child')
    find('trix-editor').send_keys([ :shift, :enter ])

    find('trix-editor[input="inline-creative-description"]').click.set('Second child')
    find('trix-editor').send_keys(:escape)

    find("#creative-#{root_creative.id}").hover
    find("#creative-#{root_creative.id} .creative-toggle-btn").click

    expect(page).to have_css("#creative-children-#{root_creative.id} > .creative-tree", count: 2)
    expect(page).to have_css("#creative-children-#{root_creative.id} > .creative-tree:nth-child(1) .creative-row", text: 'First child')
    expect(page).to have_css("#creative-children-#{root_creative.id} > .creative-tree:nth-child(2) .creative-row", text: 'Second child')
  end

  # TODO: fix this tests by fixing editor
  # it 'auto links URLs as you type' do
  #
  #   find("#creative-#{root_creative.id}").hover
  #   find("#creative-#{root_creative.id} .edit-inline-btn").click
  #   find('#inline-add').click
  #   editor = find('trix-editor')
  #   editor.send_keys('http://example.com')
  #   expect(page).to have_css('trix-editor a[href="http://example.com"]', text: 'http://example.com')
  #   editor.send_keys('/path')
  #   expect(page).to have_css('trix-editor a[href="http://example.com/path"]', text: 'http://example.com/path')
  # end
  #
  # it 'preserves links when link text is edited' do
  #
  #   find("#creative-#{root_creative.id}").hover
  #   find("#creative-#{root_creative.id} .edit-inline-btn").click
  #   find('#inline-add').click
  #   editor = find('trix-editor')
  #   editor.send_keys('http://example.com')
  #
  #   expect(page).to have_css('trix-editor a[href="http://example.com"]', text: 'http://example.com')
  #
  #   page.execute_script(
  #     "var editor = document.querySelector('trix-editor');" +
  #     "var a = editor.querySelector('a');" +
  #     "a.textContent = 'Example';" +
  #     "editor.dispatchEvent(new Event('trix-change'));"
  #   )
  #
  #   expect(page).to have_css('trix-editor a[href="http://example.com"]', text: 'Example')
  # end

  it 'maintains order when adding multiple creatives after the last node' do
    child_a = Creative.create!(description: 'A', user: user, parent: root_creative)
    child_b = Creative.create!(description: 'B', user: user, parent: root_creative)

    visit creative_path(root_creative)

    find("#creative-#{child_b.id}").hover
    find("#creative-#{child_b.id} .edit-inline-btn").click
    find('#inline-add').click
    find('trix-editor[input="inline-creative-description"]').click.set('C')
    find('#inline-add').click
    find('trix-editor[input="inline-creative-description"]').click.set('D')
    find('#inline-close').click
    wait_for_ajax

    expect(page).to have_css("#creatives > .creative-tree:nth-child(1) .creative-row", text: child_a.description.to_plain_text)
    expect(page).to have_css("#creatives > .creative-tree:nth-child(2) .creative-row", text: child_b.description.to_plain_text)
    expect(page).to have_css("#creatives > .creative-tree:nth-child(3) .creative-row", text: 'C')
    expect(page).to have_css("#creatives > .creative-tree:nth-child(4) .creative-row", text: 'D')
  end
  it 'adds as sibling when current node is collapsed' do
    child = Creative.create!(description: 'Child', user: user, parent: root_creative)
    Creative.create!(description: 'Grandchild', user: user, parent: child)

    visit creative_path(root_creative)

    find("#creative-#{child.id}").hover
    find("#creative-#{child.id} .edit-inline-btn").click
    find('#inline-add').click
    find('trix-editor[input="inline-creative-description"]').click.set('Sibling')
    find('#inline-close').click
    wait_for_ajax

    expect(page).to have_css("#creatives > .creative-tree:nth-child(1) .creative-row", text: 'Child')
    expect(page).to have_css("#creatives > .creative-tree:nth-child(3) .creative-row", text: 'Sibling')
  end

  it 'shows editor at top and saves as first child when parent context exists' do
    existing_child = Creative.create!(description: 'Existing', user: user, parent: root_creative)

    visit creative_path(root_creative)

    find('.creative-actions-row .add-creative-btn').click
    find('trix-editor[input="inline-creative-description"]').click.set('New child')
    find('#inline-close').click
    wait_for_ajax

    expect(page).to have_css("#creatives > .creative-tree:nth-child(1) .creative-row", text: 'New child')
    expect(page).to have_css("#creatives > .creative-tree:nth-child(2) .creative-row", text: existing_child.description.to_plain_text)
  end
end
