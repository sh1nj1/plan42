require 'rails_helper'

RSpec.describe 'Anonymous email filtering' do
  it 'does not send emails to the anonymous user' do
    user = User.anonymous
    ActionMailer::Base.deliveries.clear
    expect {
      UserMailer.email_verification(user)&.deliver_now
    }.not_to change { ActionMailer::Base.deliveries.size }
  end

  it 'does not create Email records for the anonymous user' do
    user = User.anonymous
    expect {
      InboxMailer.with(user: user, items: []).daily_summary&.deliver_now
    }.not_to change { Email.count }
  end
end
