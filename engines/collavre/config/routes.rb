Collavre::Engine.routes.draw do
  resources :calendar_events, only: [:destroy]
  resources :contacts, only: [:destroy]
  resources :devices, only: [:create]

  resources :inbox_items, path: "inbox", only: [ :index, :update, :destroy ] do
    get :count, on: :collection
  end

  resources :plans, only: [ :create, :destroy, :index ]

  resources :user_themes, only: [ :index, :create, :destroy ] do
    member do
      post :apply
    end
  end

  post "/creative_expanded_states/toggle", to: "creative_expanded_states#toggle"
  post "/comment_read_pointers/update", to: "comment_read_pointers#update"
end
