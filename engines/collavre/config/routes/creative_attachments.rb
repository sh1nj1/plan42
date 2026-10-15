resources :attachments, :file_drops, only: [ :create ], module: :creatives
resources :ppt_previews, only: :show, module: :creatives
