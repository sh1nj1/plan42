CollavreNotion::Engine.routes.draw do
  resources :creatives, only: [] do
    resource :notion_integration, module: :creatives, only: [ :show, :update, :destroy ]
  end
end
