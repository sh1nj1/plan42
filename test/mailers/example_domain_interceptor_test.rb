require "test_helper"

class ExampleDomainInterceptorTest < ActiveSupport::TestCase
  setup { ActionMailer::Base.deliveries.clear }
  teardown { ActionMailer::Base.deliveries.clear }

  test "does not deliver emails to example.com addresses" do
    user = User.create!(email: "blocked@example.com", password: TEST_PASSWORD, name: "Blocked")

    UserMailer.email_verification(user).deliver_now

    assert_empty ActionMailer::Base.deliveries
  end

  test "delivers emails to other domains" do
    user = User.create!(email: "allowed@domain.com", password: TEST_PASSWORD, name: "Allowed")

    UserMailer.email_verification(user).deliver_now

    assert_equal 1, ActionMailer::Base.deliveries.size
  end
end
