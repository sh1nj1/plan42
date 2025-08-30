require "test_helper"

class InboxSummaryJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    InboxItem.delete_all
  end

  test "sends summary email when user has new inbox items" do
    user = users(:one)
    InboxItem.create!(message_key: "inbox.no_messages", message_params: {}, owner: user)

    assert_emails 1 do
      InboxSummaryJob.perform_now
    end
    assert Email.order(:created_at).last.body.present?, "email body should be saved"
  end

  test "does not send email when user has no new items" do
    assert_emails 0 do
      InboxSummaryJob.perform_now
    end
  end
end
