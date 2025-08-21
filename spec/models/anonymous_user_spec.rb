require 'rails_helper'

RSpec.describe User, '.anonymous' do
  it 'has notifications disabled' do
    user = described_class.anonymous
    expect(user.notifications_enabled).to be(false)
  end
end
