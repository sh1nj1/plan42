# Public feature guides — the long-form counterpart to the empty-chat feature
# cards. Keys come from Collavre::FeatureCardRegistry, which rejects a key this
# constraint could not route, so the two cannot drift apart.
get "features", to: "features#index", as: :features
get "features/:key", to: "features#show", as: :feature, constraints: { key: Collavre::FeatureCard::GUIDE_KEY_FORMAT }

# Indexable addresses for publicly shared creatives (Collavre::PublicCreativePage)
get "p/:public_id(/:slug)", to: "creatives#public_page", as: :public_creative,
    constraints: { public_id: Collavre::Creative::Publishable::PUBLIC_ID_FORMAT }, format: false

get "robots.txt", to: "seo#robots", as: :robots, format: false
get "sitemap.xml", to: "seo#sitemap", as: :sitemap, format: false, defaults: { format: :xml }
