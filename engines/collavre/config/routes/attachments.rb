delete "/attachments/:signed_id", to: "attachments#destroy", as: :attachment
resources :ppt_previews, only: :show, module: :creatives
