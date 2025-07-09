require 'rails_helper'

RSpec.describe 'Inbox panel CSS' do
  it 'defines open state for small screens' do
    css = File.read(Rails.root.join('app/assets/stylesheets/application.css'))
    expect(css).to include('@media (max-width: 360px)')
    expect(css).to match(/#inbox-panel\.slide-panel\.open\s*\{[^\}]*right:\s*0;[^\}]*\}/)
  end
end
