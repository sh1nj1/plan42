module Collavre
  module SuccessfulAuthentication
    private

    def rotate_session_for(user)
      return_to = session[:return_to_after_authenticating]
      reset_session
      session[:return_to_after_authenticating] = return_to if return_to
      start_new_session_for(user)
    end
  end
end
