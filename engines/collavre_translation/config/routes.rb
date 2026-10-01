CollavreTranslation::Engine.routes.draw do
  resources :comments, only: [] do
    resource :translation, only: [ :show, :create ]
  end
end
