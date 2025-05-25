require "test_helper"

class CreativeTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
  include ActionMailer::TestHelper

  test "sends email notifications when back in stock" do
    creative = creatives(:tshirt)

    # Set creative out of stock
    creative.update!(progress: 0.0)

    assert_emails 2 do
      creative.update(progress: 0.99)
    end
  end
end
