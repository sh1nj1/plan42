require 'rails_helper'

RSpec.describe ExampleDomainInterceptor do
  before { ActionMailer::Base.deliveries.clear }

  it 'does not deliver emails to example.com addresses' do
    user = User.create!(email: 'blocked@example.com', password: 'secret', name: 'Blocked')
    UserMailer.email_verification(user).deliver_now
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it 'delivers emails to other domains' do
    user = User.create!(email: 'allowed@domain.com', password: 'secret', name: 'Allowed')
    UserMailer.email_verification(user).deliver_now
    expect(ActionMailer::Base.deliveries.size).to eq(1)
  end
end
