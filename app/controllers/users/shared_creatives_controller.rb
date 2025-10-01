module Users
  class SharedCreativesController < ApplicationController
    before_action :set_user
    before_action :authorize_user!
    before_action :set_creative

    def show
      @creative_shares = @creative.creative_shares
                                   .includes(:user)
                                   .where.not(permission: CreativeShare.permissions[:no_access])
                                   .references(:users)
                                   .order("users.name ASC")
    end

    private

    def set_user
      @user = User.find(params[:user_id])
    end

    def authorize_user!
      return if Current.user == @user || Current.user&.system_admin?

      head :not_found
    end

    def set_creative
      @creative = @user.creatives.find(params[:id]).effective_origin
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end
  end
end
