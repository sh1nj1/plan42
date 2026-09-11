scope "users/:user_id/agent-connection", as: :agent_connection do
  get :status, to: "agent_connections#status"
  post "auth/:engine/sessions", to: "agent_connections#create_auth_session", as: :auth_sessions
  get "auth/:engine/sessions/:session_id", to: "agent_connections#auth_session", as: :auth_session
  post "auth/:engine/sessions/:session_id", to: "agent_connections#submit_auth_session"
  delete "auth/:engine/sessions/:session_id", to: "agent_connections#cancel_auth_session"
  post "provision/sync", to: "agent_connections#provision_sync", as: :provision_sync
  post "provision/items/:type/:name/approve", to: "agent_connections#provision_approve", as: :provision_approve
  delete "provision/items/:type/:name", to: "agent_connections#provision_delete", as: :provision_delete
  post "rotate-tokens", to: "agent_connections#rotate_tokens", as: :rotate_tokens
end

scope "comments/:comment_id/agent-login", as: :inline_agent_login do
  get "/", to: "inline_agent_logins#show"
  get "status", to: "inline_agent_logins#status", as: :status
  post "sessions", to: "inline_agent_logins#create_session", as: :sessions
  get "sessions/:session_id", to: "inline_agent_logins#session", as: :session
  post "sessions/:session_id", to: "inline_agent_logins#submit"
  delete "sessions/:session_id", to: "inline_agent_logins#cancel"
  post "resume", to: "inline_agent_logins#resume", as: :resume
end
