require 'rails_helper'
require 'ostruct'

RSpec.describe 'Comments calendar command', type: :request do
  let(:user) { User.create!(email: 'user_cal@example.com', password: 'pw', name: 'User Cal') }
  let(:creative) { Creative.create!(user: user, description: 'Calendar test creative') }
  # give a user permission to feedback
  let(:share) { CreativeShare.create!(creative: creative, user: user, permission: :feedback) }

  before do
    allow_any_instance_of(CommentsController).to receive(:require_authentication).and_return(true)
    Current.session = OpenStruct.new(user: user)
    Current = OpenStruct.new(user: user)
  end

  it 'handle only date arg "/calendar 2025-08=01" and create an event' do
    # Use a valid date-only command (all-day event)
    command = "/calendar 2025-08-01"

    # Stub GoogleCalendarService to simulate successful event creation
    service = instance_double(GoogleCalendarService)
    expect(GoogleCalendarService).to receive(:new).with(user: user).and_return(service)
    expect(service).to receive(:create_event).with(
      hash_including(
        all_day: true,
        start_time: a_kind_of(Date),
        end_time: a_kind_of(Date)
      )
    ).and_return(OpenStruct.new(html_link: 'https://calendar.google.com/event/abc123'))

    expect {
      post "/creatives/#{creative.id}/comments", params: { comment: { content: command } }
    }.to change(Comment, :count).by(1)

    expect(response).to have_http_status(:created)

    created = Comment.last
    expect(created.content).to eq("#{command}\n\nevent created: https://calendar.google.com/event/abc123")
  end
end
