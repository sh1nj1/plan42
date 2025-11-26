require "test_helper"
require "cgi"

class InvitationFlowTest < ActionDispatch::IntegrationTest
  test "invitation link resolves to invitation" do
    inviter = User.create!(email: "inviter@example1.com", password: "secret", name: "Inviter")
    creative = Creative.create!(user: inviter, description: "Test creative")

    invitation = Invitation.create!(email: "invitee@example1.com",
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
    assert_match inviter.display_name, response.body
    assert_match inviter.email, response.body
    assert_match ActionController::Base.helpers.strip_tags(creative.description), response.body
    assert_select "a[href=?]", new_session_path(invite_token: token),
                  text: I18n.t("invites.show.login")
    assert_select "a[href=?]", new_user_path(invite_token: token),
                  text: I18n.t("invites.show.sign_up")
  end

  test "existing user accepts invitation by logging in" do
    inviter = User.create!(email: "inviter@example.com", password: "secret", name: "Inviter")
    creative = Creative.create!(user: inviter, description: "Test creative")
    invitee = User.create!(email: "invitee@example.com", password: "secret", name: "Invitee")
    invitee.update!(email_verified_at: Time.current)

    invitation = Invitation.create!(inviter: inviter, creative: creative, permission: :read)
    token = invitation.generate_token_for(:invite)

    post session_path, params: { email: invitee.email, password: "secret", invite_token: token }
    assert_redirected_to root_path

    invitation.reload
    assert_not_nil invitation.accepted_at
    share = CreativeShare.find_by(creative: creative, user: invitee)
    assert share
    assert_equal "read", share.permission
  end
end
