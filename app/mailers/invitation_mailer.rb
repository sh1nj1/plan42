class InvitationMailer < ApplicationMailer
  def invite
    @invitation = params[:invitation]
    email = mail to: @invitation.email, subject: t("invitation_mailer.invite.subject")
    Email.create!(
      email: @invitation.email,
      subject: email.subject,
      body: extract_body(email),
      event: :invitation
    )
  end
end
