module Collavre
  class Configuration
    attr_accessor :user_class_name, :current_user_method

    def initialize
      @user_class_name = "User"
      @current_user_method = -> { Current.user }
    end

    def user_class
      @user_class_name.constantize
    end
  end
end
