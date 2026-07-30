require "test_helper"
require "cgi"

class InvitationFlowTest < ActionDispatch::IntegrationTest
  test "invitation link resolves to invitation" do
    inviter = User.create!(email: "inviter@example1.com", password: TEST_PASSWORD, name: "Inviter")
    creative = Creative.create!(user: inviter, description: "Test creative")

    invitation = Invitation.create!(email: "invitee@example1.com",
                                    inviter: inviter,
                                    creative: creative,
                                    permission: :read)

    ActionMailer::Base.deliveries.clear
    Collavre::InvitationMailer.with(invitation: invitation).invite.deliver_now

    mail = ActionMailer::Base.deliveries.last
    email_record = Email.order(:created_at).last
    assert email_record.body.present?, "email body should be saved"
    body = mail.text_part ? mail.text_part.body.decoded : mail.body.decoded
    token = CGI.unescape(body[/token=([^"\s]+)/, 1])
    assert token.present?, "token should be present in email"

    assert_nil invitation.clicked_at
    get collavre.invite_path(token: token)
    assert_response :success

    invitation.reload
    assert_not_nil invitation.clicked_at
    assert_match inviter.display_name, response.body
    assert_match inviter.email, response.body
    assert_match ActionController::Base.helpers.strip_tags(creative.description), response.body
    meta_title = I18n.t("collavre.invites.show.meta.title", creative: "Test creative")
    meta_description = I18n.t("collavre.invites.show.meta.description", inviter: inviter.display_name)
    assert_select "title", text: meta_title
    assert_select 'meta[property="og:type"][content="website"]', count: 1
    assert_select 'meta[property="og:site_name"]', count: 1 do |tags|
      assert_equal I18n.t("app.name"), tags.first["content"]
    end
    assert_select 'meta[property="og:title"]', count: 1 do |tags|
      assert_equal meta_title, tags.first["content"]
    end
    assert_select 'meta[property="og:description"]', count: 1 do |tags|
      assert_equal meta_description, tags.first["content"]
    end
    assert_select 'meta[property="og:url"]', count: 1 do |tags|
      assert_equal collavre.invite_url(token: token), tags.first["content"]
    end
    assert_select 'meta[property="og:image"]', count: 1 do |tags|
      assert_equal "http://www.example.com/icon-1e3cf549d2.png", tags.first["content"]
    end
    assert_select "a[href=?]", collavre.new_session_path(invite_token: token),
                  text: I18n.t("collavre.invites.show.login")
    assert_select "a[href=?]", collavre.new_user_path(invite_token: token),
                  text: I18n.t("collavre.invites.show.sign_up")
  end

  test "existing user accepts invitation by logging in" do
    inviter = User.create!(email: "inviter@example.com", password: TEST_PASSWORD, name: "Inviter")
    creative = Creative.create!(user: inviter, description: "Test creative")
    invitee = User.create!(email: "invitee@example.com", password: TEST_PASSWORD, name: "Invitee")
    invitee.update!(email_verified_at: Time.current)

    invitation = Invitation.create!(inviter: inviter, creative: creative, permission: :read)
    token = invitation.generate_token_for(:invite)

    post session_path, params: { email: invitee.email, password: TEST_PASSWORD, invite_token: token }
    assert_redirected_to root_path

    invitation.reload
    assert_not_nil invitation.accepted_at
    share = CreativeShare.find_by(creative: creative, user: invitee)
    assert share
    assert_equal "read", share.permission
  end

  test "invitation metadata is localized and strips markup from the creative title" do
    inviter = User.create!(email: "inviter-ko@example.com", password: TEST_PASSWORD, name: "초대자")
    creative = Creative.create!(user: inviter, description: "<strong>로드맵 &amp; 출시</strong>")
    invitation = Invitation.create!(inviter: inviter, creative: creative, permission: :read)
    token = invitation.generate_token_for(:invite)

    get collavre.invite_path(token: token), headers: { "Accept-Language" => "ko" }

    assert_response :success
    expected_title = I18n.t("collavre.invites.show.meta.title", locale: :ko, creative: "로드맵 & 출시")
    expected_description = I18n.t("collavre.invites.show.meta.description",
                                  locale: :ko,
                                  inviter: inviter.display_name)
    assert_select 'meta[property="og:title"]', count: 1 do |tags|
      assert_equal expected_title, tags.first["content"]
    end
    assert_select 'meta[property="og:description"]', count: 1 do |tags|
      assert_equal expected_description, tags.first["content"]
    end
  end

  test "link preview crawlers do not mark the invitation as clicked" do
    inviter = User.create!(email: "preview-inviter@example.com", password: TEST_PASSWORD, name: "Inviter")
    creative = Creative.create!(user: inviter, description: "Preview creative")
    invitation = Invitation.create!(inviter: inviter, creative: creative, permission: :read)
    token = invitation.generate_token_for(:invite)
    user_agents = [
      "Slackbot-LinkExpanding 1.0",
      "facebookexternalhit/1.1",
      "KAKAOTALK-SCRAP/1.0",
      "WhatsApp/2.23"
    ]

    user_agents.each do |user_agent|
      get collavre.invite_path(token: token), headers: { "User-Agent" => user_agent }

      assert_response :success
      assert_nil invitation.reload.clicked_at, user_agent
      assert_select 'meta[property="og:title"]', count: 1
    end
  end
end
