require "test_helper"

class CreativeMailerTest < ActionMailer::TestCase
  test "in_stock" do
    mail = CreativeMailer.with(creative: creatives(:tshirt), subscriber: subscribers(:david)).in_stock
    assert_equal "In stock", mail.subject
    assert_equal [ "david@example.org" ], mail.to
    assert_match "Good news!", mail.body.encoded
  end
end
