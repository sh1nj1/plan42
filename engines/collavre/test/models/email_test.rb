require "test_helper"

class EmailTest < ActiveSupport::TestCase
  test "is valid with minimal attributes" do
    email = Email.new(
      email: "test@example.com",
      subject: "Hello",
      body: "body",
      event: :invitation
    )

    assert email.valid?
  end
end
