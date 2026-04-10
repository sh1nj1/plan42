module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      set_current_user || set_current_user_from_token || reject_unauthorized_connection
    end

    private
      def set_current_user
        if session = Session.find_by(id: cookies.signed[:session_id])
          self.current_user = session.user
        end
      end

      # Token-based auth for non-browser clients (e.g. MCP plugin).
      # Token is passed as a query parameter: /cable?token=xxx
      def set_current_user_from_token
        token = request.params[:token]
        return nil if token.blank?

        access_token = Doorkeeper::AccessToken.by_token(token)
        return nil unless access_token&.accessible?

        user = Collavre::User.find_by(id: access_token.resource_owner_id)
        return nil unless user

        self.current_user = user
      end
  end
end
