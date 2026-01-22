# Be sure to restart your server when you modify this file.

# Version of your assets, change this if you want to expire all your assets.
Rails.application.config.assets.version = "1.0"

# Add additional assets to the asset load path.
# Rails.application.config.assets.paths << Emoji.images_path

# Add Collavre engine stylesheets to asset paths for Propshaft
Rails.application.config.assets.paths << Rails.root.join("engines/collavre/app/assets/stylesheets")

Rails.application.config.assets.precompile += %w[slide_view.js slide_view.css]
