module Webauthn
  class SessionsController < ApplicationController
    allow_unauthenticated_access only: [ :new, :create ]

    def new
      get_options = WebAuthn::Credential.options_for_get

      session[:authentication_challenge] = get_options.challenge

      render json: get_options
    end

    def create
      webauthn_credential = WebAuthn::Credential.from_get(params)

      credential = WebauthnCredential.find_by(webauthn_id: webauthn_credential.id)

      if credential
        begin
          webauthn_credential.verify(
            session[:authentication_challenge],
            public_key: credential.public_key,
            sign_count: credential.sign_count
          )

          credential.update!(sign_count: webauthn_credential.sign_count)

          if credential.user.email_verified?
            handle_invitation_for(credential.user) if params[:invite_token].present?
            start_new_session_for credential.user
            render json: { status: "ok", redirect_url: after_authentication_url }, status: :ok
          else
            render json: { status: "error", message: I18n.t("users.sessions.new.email_not_verified") }, status: :unprocessable_entity
          end
        rescue WebAuthn::Error => e
          render json: { status: "error", message: "Verification failed: #{e.message}" }, status: :unprocessable_entity
        ensure
          session.delete(:authentication_challenge)
        end
      else
        session.delete(:authentication_challenge)
        render json: { status: "error", message: I18n.t("users.webauthn.credential_not_found") }, status: :unprocessable_entity
      end
    end
  end
end
