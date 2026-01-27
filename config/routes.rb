Rails.application.routes.draw do
  # Mount Collavre engine - all core functionality is in the engine
  mount Collavre::Engine => "/"

  # Doorkeeper OAuth provider
  use_doorkeeper do
    controllers applications: "oauth/applications"
  end

  # Extending Doorkeeper applications routes
  resources :oauth_applications, controller: "oauth/applications", as: :oauth_applications, only: [] do
    member do
      post :create_access_token
      delete :destroy_access_token
    end
  end

  # WebAuthn passkey authentication (host app specific)
  namespace :webauthn do
    resource :registration, only: [ :new, :create ]
    resource :session, only: [ :new, :create ]
    resources :credentials, only: [ :destroy ]
  end

  # Health check
  get "up" => "rails/health#show", as: :rails_health_check

  # PWA manifest and service worker
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Root path
  root "collavre/creatives#index"

  # Admin settings (host app specific)
  get "/admin", to: "admin/settings#index"
  namespace :admin do
    resource :settings, only: [ :update ]
  end

  # Creative integrations (GitHub/Notion)
  resources :creatives, only: [] do
    resource :github_integration, only: [ :show, :update, :destroy ], module: :creatives
    resource :notion_integration, only: [ :show, :update, :destroy ], module: :creatives
  end

  # GitHub account and webhooks
  namespace :github do
    resource :account, only: [ :show ] do
      get :organizations
      get :repositories
    end
    post :webhook, to: "webhooks#create"
  end

  # MCP OAuth Discovery
  get "/.well-known/oauth-protected-resource", to: "mcp/discovery#oauth_protected_resource"
  get "/.well-known/oauth-authorization-server", to: "mcp/discovery#oauth_authorization_server"
end
