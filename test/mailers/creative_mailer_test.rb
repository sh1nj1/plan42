require "test_helper"

class CreativeMailerTest < ActionMailer::TestCase
  test "in_stock" do
    mail = CreativeMailer.with(creative: creatives(:tshirt), subscriber: subscribers(:david)).in_stock
    assert_equal I18n.t("creative_mailer.in_stock.subject"), mail.subject
    assert_equal [ "david@example.org" ], mail.to
    assert_match I18n.t("creative_mailer.in_stock.subject"), mail.body.encoded
  end
end
