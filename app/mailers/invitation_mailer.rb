class InvitationMailer < ApplicationMailer
  def invite
    @invitation = params[:invitation]
    mail to: @invitation.email, subject: t("invitation_mailer.invite.subject")
  end
end
