module Collavre
  module CreativeRenderers
    REGISTRY = {
      "json" => Collavre::CreativeRenderers::Json,
      "menu" => Collavre::CreativeRenderers::Menu
    }.freeze

    def self.for(kind)
      REGISTRY[kind]
    end
  end
end
