module Collavre
  module UsersController::AiProfileAccess
    extend ActiveSupport::Concern

    private

    def ai_profile_editable?
      Current.user.system_admin? || @user.created_by_id == Current.user.id
    end

    def verify_ai_profile_access
      return if ai_profile_editable? || @user.searchable? || shared_ai_profile?

      return if Current.user.contact_users.where(id: @user.id).exists?

      head :not_found
    end

    def shared_ai_profile?
      ids = @user.creative_shares_caches.where(permission: [ :feedback, :write, :admin ]).pluck(:creative_id)
      ids |= Collavre::Creative.where(user_id: @user.id).pluck(:id)
      Creatives::PermissionFilter.new(user: Current.user).readable_ids(ids).any?
    end
  end
end
