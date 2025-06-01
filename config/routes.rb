Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"

  root "creatives#index"

  resources :users, only: [ :new, :create, :index, :show ] do
    member do
      get :edit_password
      patch :update_password
    end
  end

  resources :creatives do
    resources :subscribers, only: [ :create ]
    resources :creative_shares, only: [ :create ]
    resources :comments, only: [ :index, :create, :destroy ]
    collection do
      post :recalculate_progress
      post :reorder
      post :import_markdown
      post :set_plan
      post :remove_plan
      get :append_as_parent, to: "creatives#append_as_parent", as: :append_as_parent_creative
    end
    member do
      post :share, to: "creatives#share", as: :share_creative
    end
  end

  resources :plans, only: [ :create, :destroy ]

  resource :unsubscribe, only: [ :show ]
end
