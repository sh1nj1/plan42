module Collavre
  class PasswordsMailer < ApplicationMailer
    helper Collavre::Engine.routes.url_helpers

    def reset(user)
      @user = user
      mail subject: "Reset your password", to: user.email
    end
  end
end
