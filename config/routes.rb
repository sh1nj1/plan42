Rails.application.routes.draw do
  # Mount Collavre engine - routes will be gradually migrated here
  mount Collavre::Engine => "/"

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

  resource :session
  match "/auth/google_oauth2/callback", to: "google_auth#callback", via: [ :get, :post ]
  match "/auth/github/callback", to: "github_auth#callback", via: [ :get, :post ]
  get "/auth/notion", to: "notion_auth#authorize"
  get "/auth/notion/callback", to: "notion_auth#callback", as: :notion_auth_callback
  resources :passwords, param: :token
  namespace :webauthn do
    resource :registration, only: [ :new, :create ]
    resource :session, only: [ :new, :create ]
    resources :credentials, only: [ :destroy ]
  end
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # Home page path is rewritten by HomePathRewriter middleware
  # Default: /creatives, configurable via SystemSetting.home_page_path
  root "collavre/creatives#index"

  resources :users, only: [ :new, :create, :index, :show, :update, :destroy ] do
    member do
      get :edit_password
      patch :update_password
      patch :grant_system_admin
      patch :revoke_system_admin
      get :edit_ai
      patch :update_ai
      get :passkeys
    end
    collection do
      get :exists
      get :search
      patch :notification_settings
      get :new_ai
      post :create_ai
    end
  end

  get "/admin", to: "admin/settings#index"
  namespace :admin do
    resource :settings, only: [ :update ]
  end

  # creatives routes moved to Collavre engine
  # Keep integration routes nested under creatives for now
  resources :creatives, only: [] do
    resource :github_integration, only: [ :show, :update, :destroy ], module: :creatives
    resource :notion_integration, only: [ :show, :update, :destroy ], module: :creatives
  end

  # comments routes moved to Collavre engine

  # creative_imports and creative_plan routes moved to Collavre engine

  # plans routes moved to Collavre engine

  # calendar_events routes moved to Collavre engine

  # inbox_items routes moved to Collavre engine

  # contacts and devices routes moved to Collavre engine

  # emails and invite routes moved to Collavre engine
  resource :verify, controller: "email_verifications", only: [ :show ]

  # user_themes routes moved to Collavre engine

  namespace :github do
    resource :account, only: [ :show ] do
      get :organizations
      get :repositories
    end
    post :webhook, to: "webhooks#create"
  end

  # creative_expanded_states and comment_read_pointers routes moved to Collavre engine

  # Attachment deletion
  delete "/attachments/:signed_id", to: "attachments#destroy", as: :attachment

  # MCP OAuth Discovery
  get "/.well-known/oauth-protected-resource", to: "mcp/discovery#oauth_protected_resource"
  get "/.well-known/oauth-authorization-server", to: "mcp/discovery#oauth_authorization_server"
end
