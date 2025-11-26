Rails.application.routes.draw do
  resource :session
  match "/auth/google_oauth2/callback", to: "google_auth#callback", via: [ :get, :post ]
  match "/auth/github/callback", to: "github_auth#callback", via: [ :get, :post ]
  get "/auth/notion", to: "notion_auth#authorize"
  get "/auth/notion/callback", to: "notion_auth#callback", as: :notion_auth_callback
  resources :passwords, param: :token
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"

  root "creatives#index"

  resources :users, only: [ :new, :create, :index, :show, :update, :destroy ] do
    member do
      get :edit_password
      patch :update_password
      patch :grant_system_admin
      patch :revoke_system_admin
    end
    collection do
      get :exists
      get :search
      patch :notification_settings
      get :new_ai
      post :create_ai
    end
  end

  resources :creatives do
    resource :github_integration, only: [ :show, :update, :destroy ], module: :creatives
    resource :notion_integration, only: [ :show, :update, :destroy ], module: :creatives
    resources :subscribers, only: [ :create ]
    resources :creative_shares, only: [ :create, :destroy ]
      resources :comments, only: [ :index, :create, :destroy, :show, :update ] do
        member do
          post :convert
          post :approve
          patch :update_action
        end
        collection do
          get :participants
          post :move
        end
      end
    collection do
      post :recalculate_progress
      post :reorder
      post :link_drop
      get :append_as_parent, to: "creatives#append_as_parent", as: :append_as_parent_creative
      get :append_below, to: "creatives#append_below", as: :append_below_creative
      get :export_markdown
    end
    member do
      get :children
      post :share, to: "creatives#share", as: :share_creative
      post :request_permission, to: "creatives#request_permission"
      post :unconvert
      get :parent_suggestions
      get :slide_view
    end
  end

  resources :creative_imports, only: [ :create ]
  resource :creative_plan, only: [ :create, :destroy ], controller: "creative_plans"

  resources :plans, only: [ :create, :destroy, :index ]

  resources :calendar_events, only: [ :destroy ]

  resources :inbox_items, path: "inbox", only: [ :index, :update, :destroy ] do
    get :count, on: :collection
  end

  resources :contacts, only: [ :destroy ]

  resources :devices, only: [ :create ]

  resources :emails, only: [ :index, :show ]

  resource :unsubscribe, only: [ :show ]
  resource :invite, only: [ :show, :create ]
  resource :verify, controller: "email_verifications", only: [ :show ]

  namespace :github do
    resource :account, only: [ :show ] do
      get :organizations
      get :repositories
    end
    post :webhook, to: "webhooks#create"
  end

  post "/creative_expanded_states/toggle", to: "creative_expanded_states#toggle"
  post "/comment_read_pointers/update", to: "comment_read_pointers#update"

  # Attachment deletion
  delete "/attachments/:signed_id", to: "attachments#destroy", as: :attachment
end
