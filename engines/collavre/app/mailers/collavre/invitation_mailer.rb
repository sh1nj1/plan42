module Collavre
  class InvitationMailer < ApplicationMailer
    helper Collavre::Engine.routes.url_helpers

    def invite
      @invitation = params[:invitation]
      email = mail to: @invitation.email, subject: I18n.t("collavre.invitation_mailer.invite.subject")
      Collavre::Email.create!(
        email: @invitation.email,
        subject: email.subject,
        body: extract_body(email),
        event: :invitation
      )
    end
  end
end
