require "test_helper"
require "cgi"

class InvitationFlowTest < ActionDispatch::IntegrationTest
  test "invitation link resolves to invitation" do
    inviter = User.create!(email: "inviter@example.com", password: "secret")
    creative = Creative.create!(user: inviter, description: "Test creative")

    invitation = Invitation.create!(email: "invitee@example.com",
                                    inviter: inviter,
                                    creative: creative,
                                    permission: :read)

    ActionMailer::Base.deliveries.clear
    InvitationMailer.with(invitation: invitation).invite.deliver_now

    mail = ActionMailer::Base.deliveries.last
    email_record = Email.order(:created_at).last
    assert email_record.body.present?, "email body should be saved"
    body = mail.text_part ? mail.text_part.body.decoded : mail.body.decoded
    token = CGI.unescape(body[/token=([^"\s]+)/, 1])
    assert token.present?, "token should be present in email"

    assert_nil invitation.clicked_at
    get invite_path(token: token)
    assert_response :success

    invitation.reload
    assert_not_nil invitation.clicked_at
    assert_select "input[name=invite_token][value=?]", token
    assert_select "input[name='user[email]'][readonly][value=?]", "invitee@example.com"
  end
end
