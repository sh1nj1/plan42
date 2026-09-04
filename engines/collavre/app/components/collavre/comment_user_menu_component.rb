module Collavre
  class CommentUserMenuComponent < ViewComponent::Base
    def initialize(user:, menu_id:)
      @user = user
      @menu_id = menu_id
    end

    attr_reader :user, :menu_id

    def ai_user?
      user.ai_user?
    end

    def profile_path
      helpers.collavre.user_path(user)
    end

    def trigger_actions
      actions = [ "click->popup-menu#toggle" ]
      actions.concat(%w[dragstart->comment-user-menu#dragStart dragend->comment-user-menu#dragEnd]) if ai_user?
      actions.join(" ")
    end
  end
end
