module Collavre
  module CreativeRenderers
    REGISTRY = {
      "menu" => Collavre::CreativeRenderers::Menu
    }.freeze

    def self.for(kind)
      REGISTRY[kind]
    end
  end
end
