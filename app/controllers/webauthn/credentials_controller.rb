module Webauthn
  class CredentialsController < ApplicationController
    def destroy
      credential = Current.user.webauthn_credentials.find(params[:id])
      credential.destroy
      redirect_back fallback_location: root_path, notice: I18n.t("users.webauthn.deleted")
    end
  end
end
