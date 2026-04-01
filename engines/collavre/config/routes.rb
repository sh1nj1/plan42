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
      patch :notification_settings
    end
    member do
      get :edit_ai
      patch :update_ai
      patch :grant_system_admin
      patch :revoke_system_admin
      patch :unlock
      patch :lock
      get :edit_password
      patch :update_password
      get :passkeys
    end
  end
  get "/email_verification/:token", to: "email_verifications#show", as: :email_verification

  # OAuth callback routes (paths match OmniAuth provider names)
  match "/auth/google_oauth2/callback", to: "google_auth#callback", via: [ :get, :post ]

  delete "/attachments/:signed_id", to: "attachments#destroy", as: :attachment

  resources :calendar_events, only: [ :destroy ]
  resources :contacts, only: [ :destroy ]
  resources :devices, only: [ :create ]

  resources :inbox_items, path: "inbox", only: [ :index, :update, :destroy ] do
    get :count, on: :collection
  end

  resources :user_themes, only: [ :index, :create, :destroy ] do
    member do
      post :apply
    end
  end

  resources :creative_imports, only: [ :create ]
  resources :creatives do
    resources :creative_shares, only: [ :index, :create, :update, :destroy ]
    resources :invitations, only: [ :update, :destroy ], controller: "creative_invitations"
    resources :topics, only: [ :index, :create, :update, :destroy ] do
      collection do
        post :reorder
        get :next_name
      end
      member do
        patch :move
        patch :archive
        patch :unarchive
        patch :set_primary_agent
      end
    end
    resources :comments, only: [ :index, :create, :destroy, :show, :update ] do
      member do
        post :convert
        post :approve
        patch :update_action
        delete :reactions, to: "comments/reactions#destroy"
        get :download_images
        delete :remove_image
      end

      resources :reactions, only: [ :create ], module: :comments
      resource :activity_log, only: [ :show ], module: :comments
      resources :versions, only: [ :index, :destroy ], module: :comments do
        member do
          post :select
        end
      end

      collection do
        get :participants
        get :fullscreen
        post :move
        delete :batch_destroy
        post :merge
        get :commands

        resources :snapshots, only: [ :index ], module: :comments do
          member do
            post :restore
          end
        end
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
      patch :archive
      patch :unarchive
      get :parent_suggestions
      get :slide_view
      get :contexts
      patch :update_contexts
      patch :update_metadata
      patch :trigger_action
    end
  end

  resources :emails, only: [ :index, :show ]
  resource :invite, only: [ :show, :create ]

  post "/creative_expanded_states/toggle", to: "user_creative_preferences#toggle"
  patch "/creatives/:creative_id/user_creative_preferences/update_last_topic", to: "user_creative_preferences#update_last_topic", as: :update_last_topic
  post "/comment_read_pointers/update", to: "comment_read_pointers#update"

  # Admin settings & orchestration
  scope "/admin", as: :admin do
    get "/", to: "admin/settings#index", as: :settings
    patch "/", to: "admin/settings#update"
    get "/uiux", to: "admin/settings#uiux", as: :uiux
    patch "/uiux", to: "admin/settings#update_uiux"
    resource :orchestration, only: [ :show, :update ], controller: "admin/orchestration"
  end
end
