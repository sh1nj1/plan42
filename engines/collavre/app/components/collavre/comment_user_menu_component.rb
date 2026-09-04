module Collavre
  class CommentUserMenuComponent < ViewComponent::Base
    def initialize(user:, menu_id:)
      @user = user
      @menu_id = menu_id
    end

    attr_reader :user, :menu_id

    def profile_path
      helpers.collavre.user_path(user)
    end
  end
end
