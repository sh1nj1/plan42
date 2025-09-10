require 'rails_helper'

RSpec.describe Creative, type: :model do
  let(:user) { User.create!(email: 'user@example.com', password: 'pw', name: 'User') }
  let(:creative) { Creative.create!(user: user, description: 'Slide') }

  it 'returns prompt without prefix' do
    creative.comments.create!(user: user, content: '> Hello world', private: true)
    expect(creative.prompt_for(user)).to eq('Hello world')
  end

  it 'returns nil when no prompt' do
    expect(creative.prompt_for(user)).to be_nil
  end
end
