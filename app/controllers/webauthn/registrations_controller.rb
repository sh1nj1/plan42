module Webauthn
  class RegistrationsController < ApplicationController
    def new
      Current.user.update!(webauthn_id: WebAuthn.generate_user_id) unless Current.user.webauthn_id

      create_options = WebAuthn::Credential.options_for_create(
        user: {
          id: Current.user.webauthn_id,
          name: Current.user.email,
          display_name: Current.user.name
        },
        exclude: Current.user.webauthn_credentials.pluck(:webauthn_id)
      )

      session[:creation_challenge] = create_options.challenge

      render json: create_options
    end

    def create
      webauthn_credential = WebAuthn::Credential.from_create(params)

      begin
        webauthn_credential.verify(session[:creation_challenge])

        credential = Current.user.webauthn_credentials.build(
          webauthn_id: webauthn_credential.id,
          public_key: webauthn_credential.public_key,
          sign_count: webauthn_credential.sign_count,
          nickname: params[:nickname]
        )

        if credential.save
          render json: { status: "ok" }, status: :created
        else
          render json: { status: "error", message: "Credential could not be saved" }, status: :unprocessable_entity
        end
      rescue WebAuthn::Error => e
        render json: { status: "error", message: "Verification failed: #{e.message}" }, status: :unprocessable_entity
      ensure
        session.delete(:creation_challenge)
      end
    end
  end
end
