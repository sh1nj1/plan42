require_relative "lib/collavre_translation/version"

Gem::Specification.new do |spec|
  spec.name = "collavre_translation"
  spec.version = CollavreTranslation::VERSION
  spec.authors = [ "Collavre" ]
  spec.summary = "Optional comment translation for Collavre"
  spec.license = "AGPL"
  spec.files = Dir.chdir(__dir__) { Dir["{app,config,db,lib}/**/*", "README.md"] }
  spec.add_dependency "rails", ">= 8.0"
  spec.add_dependency "collavre"
  spec.add_dependency "cld3", "~> 3.6"
end
