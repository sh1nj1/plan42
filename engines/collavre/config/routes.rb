Collavre::Engine.routes.draw do
  resources :calendar_events, only: [:destroy]
  resources :contacts, only: [:destroy]
  resources :devices, only: [:create]

  post "/creative_expanded_states/toggle", to: "creative_expanded_states#toggle"
  post "/comment_read_pointers/update", to: "comment_read_pointers#update"
end
