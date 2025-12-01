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

    private

    def authenticate_user!
      redirect_to new_session_url unless Current.user
    end
  end
end
