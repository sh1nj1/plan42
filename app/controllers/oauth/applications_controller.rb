module Oauth
  class ApplicationsController < Doorkeeper::ApplicationsController
    layout "application"

    before_action :authenticate_user!

    def index
      @applications = current_resource_owner.oauth_applications
    end

    def create
      @application = Doorkeeper::Application.new(application_params)
      @application.owner = current_resource_owner if Doorkeeper.configuration.confirm_application_owner?

      if @application.save
        flash[:notice] = I18n.t(:notice, scope: [ :doorkeeper, :flash, :applications, :create ])
        redirect_to oauth_application_url(@application)
      else
        render :new
      end
    end

    def create_access_token
      @application = current_resource_owner.oauth_applications.find(params[:id])

      # Calculate expiration
      expires_in = case params[:expiration_type]
      when "never"
                     nil # Never expires (or max integer if DB requires it, but Doorkeeper supports nil)
      when "custom"
                     days = params[:expires_in_days].to_i
                     days > 0 ? days.days.to_i : Doorkeeper.configuration.access_token_expires_in
      else # '1_month' or default
                     1.month.to_i
      end

      # Create a new access token (allowing multiple tokens)
      token = Doorkeeper::AccessToken.create!(
        application: @application,
        resource_owner_id: current_resource_owner.id,
        scopes: Doorkeeper.configuration.default_scopes,
        expires_in: expires_in,
        use_refresh_token: Doorkeeper.configuration.refresh_token_enabled?
      )

      flash[:access_token] = token.token
      flash[:notice] = I18n.t("doorkeeper.applications.personal_access_token.flash.create_notice")
      redirect_to oauth_application_url(@application)
    end

    def destroy_access_token
      @application = current_resource_owner.oauth_applications.find(params[:id])
      token = Doorkeeper::AccessToken.find_by(id: params[:token_id], application_id: @application.id, resource_owner_id: current_resource_owner.id)

      if token&.revoke
        flash[:notice] = I18n.t("doorkeeper.applications.personal_access_token.flash.revoke_notice")
      else
        flash[:alert] = I18n.t("doorkeeper.applications.personal_access_token.flash.revoke_error")
      end

      redirect_to oauth_application_url(@application)
    end

    private

    def authenticate_user!
      redirect_to new_session_url unless Current.user
    end
  end
end
