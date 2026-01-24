Collavre::Engine.routes.draw do
  # Authentication routes
  resource :session, only: [ :new, :create, :destroy ]
  resources :passwords, param: :token, only: [ :new, :create, :edit, :update ]
  resources :users, only: [ :index, :new, :create, :show, :edit, :update, :destroy ] do
    collection do
      get :new_ai
      post :create_ai
      get :search
      get :exists
    end
    member do
      get :edit_ai
      patch :update_ai
      patch :grant_system_admin
      patch :revoke_system_admin
      get :edit_password
      patch :update_password
      get :passkeys
      patch :notification_settings
    end
  end
  get "/email_verification/:token", to: "email_verifications#show", as: :email_verification

  # OAuth callback routes (paths match OmniAuth provider names)
  match "/auth/google_oauth2/callback", to: "google_auth#callback", via: [ :get, :post ]
  match "/auth/github/callback", to: "github_auth#callback", via: [ :get, :post ]
  match "/auth/notion/callback", to: "notion_auth#callback", via: [ :get, :post ]

  delete "/attachments/:signed_id", to: "attachments#destroy", as: :attachment

  resources :calendar_events, only: [ :destroy ]
  resources :contacts, only: [ :destroy ]
  resources :devices, only: [ :create ]

  resources :inbox_items, path: "inbox", only: [ :index, :update, :destroy ] do
    get :count, on: :collection
  end

  resources :plans, only: [ :create, :destroy, :index ]

  resources :user_themes, only: [ :index, :create, :destroy ] do
    member do
      post :apply
    end
  end

  resources :creative_imports, only: [ :create ]
  resource :creative_plan, only: [ :create, :destroy ], controller: "creative_plans"

  resources :creatives do
    resources :creative_shares, only: [ :create, :destroy ]
    resources :topics, only: [ :index, :create, :destroy ]
    resources :comments, only: [ :index, :create, :destroy, :show, :update ] do
      member do
        post :convert
        post :approve
        patch :update_action
        delete :reactions, to: "comments/reactions#destroy"
      end

      resources :reactions, only: [ :create ], module: :comments
      resource :activity_log, only: [ :show ], module: :comments

      collection do
        get :participants
        post :move
      end
    end
    collection do
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

  resources :emails, only: [ :index, :show ]
  resource :invite, only: [ :show, :create ]

  post "/creative_expanded_states/toggle", to: "creative_expanded_states#toggle"
  post "/comment_read_pointers/update", to: "comment_read_pointers#update"
end
