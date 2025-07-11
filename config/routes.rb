Rails.application.routes.draw do
  resource :session
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

  resources :users, only: [ :new, :create, :index, :show, :update ] do
    member do
      get :edit_password
      patch :update_password
    end
    collection do
      get :exists
      get :search
    end
  end

  resources :creatives do
    resources :subscribers, only: [ :create ]
    resources :creative_shares, only: [ :create, :destroy ]
    resources :comments, only: [ :index, :create, :destroy, :show, :update ]
    collection do
      post :recalculate_progress
      post :reorder
      post :import_markdown
      post :set_plan
      post :remove_plan
      get :append_as_parent, to: "creatives#append_as_parent", as: :append_as_parent_creative
      get :append_below, to: "creatives#append_below", as: :append_below_creative
      get :export_markdown
    end
    member do
      get :children
      post :share, to: "creatives#share", as: :share_creative
    end
  end

  resources :plans, only: [ :create, :destroy, :index ]

  resources :inbox_items, path: "inbox", only: [ :index, :update, :destroy ] do
    get :count, on: :collection
  end

  resources :emails, only: [ :index, :show ]

  resource :unsubscribe, only: [ :show ]
  resource :invite, only: [ :show ]
  resource :verify, controller: "email_verifications", only: [ :show ]

  post "/creative_expanded_states/toggle", to: "creative_expanded_states#toggle"
  post "/comment_read_pointers/update", to: "comment_read_pointers#update"
end
