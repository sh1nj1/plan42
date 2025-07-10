require "test_helper"
require "cgi"

class EmailVerificationFlowTest < ActionDispatch::IntegrationTest
  test "verification link verifies user" do
    ActionMailer::Base.deliveries.clear
    post users_path, params: { user: { email: "verify@example.com", password: "secret", password_confirmation: "secret", name: "Verify" } }
    user = User.find_by(email: "verify@example.com")
    assert_not_nil user
    assert_nil user.email_verified_at

    mail = ActionMailer::Base.deliveries.last
    body = mail.text_part ? mail.text_part.body.decoded : mail.body.decoded
    token = CGI.unescape(body[/token=([^"\s]+)/, 1])
    assert token.present?, "token should be present in email"

    get verify_path(token: token)
    assert_redirected_to new_session_path
    follow_redirect!
    assert_match I18n.t("users.email_verified"), response.body

    user.reload
    assert_not_nil user.email_verified_at
  end
end
