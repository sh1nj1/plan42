module Webauthn
  class SessionsController < ApplicationController
    include WebauthnChallenge

    allow_unauthenticated_access only: [ :new, :create ]
    before_action -> { enforce_auth_provider!(:passkey) }, only: %i[new create]

    CHALLENGE_KEY = :authentication_challenge

    def new
      get_options = WebAuthn::Credential.options_for_get

      store_challenge(CHALLENGE_KEY, get_options.challenge)

      render json: get_options
    end

    def create
      webauthn_credential = WebAuthn::Credential.from_get(params)

      credential = WebauthnCredential.find_by(webauthn_id: webauthn_credential.id)

      if credential
        begin
          webauthn_credential.verify(
            consume_challenge(CHALLENGE_KEY),
            public_key: credential.public_key,
            sign_count: credential.sign_count
          )

          credential.update!(sign_count: webauthn_credential.sign_count)

          if credential.user.email_verified?
            handle_invitation_for(credential.user) if params[:invite_token].present?
            return_to = session[:return_to_after_authenticating]
            reset_session
            session[:return_to_after_authenticating] = return_to if return_to
            start_new_session_for credential.user
            render json: { status: "ok", redirect_url: after_authentication_url }, status: :ok
          else
            render json: { status: "error", message: I18n.t("users.sessions.new.email_not_verified") }, status: :unprocessable_entity
          end
        rescue WebAuthn::Error => e
          render json: { status: "error", message: I18n.t("users.webauthn.verification_failed", message: e.message) }, status: :unprocessable_entity
        end
      else
        consume_challenge(CHALLENGE_KEY)
        render json: { status: "error", message: I18n.t("users.webauthn.credential_not_found") }, status: :unprocessable_entity
      end
    end
  end
end
