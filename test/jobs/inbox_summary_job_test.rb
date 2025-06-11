require "test_helper"

class InboxSummaryJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    InboxItem.delete_all
  end

  test "sends summary email when user has new inbox items" do
    user = users(:one)
    InboxItem.create!(message: "hi", owner: user)

    assert_emails 1 do
      InboxSummaryJob.perform_now
    end
  end

  test "does not send email when user has no new items" do
    assert_emails 0 do
      InboxSummaryJob.perform_now
    end
  end
end
