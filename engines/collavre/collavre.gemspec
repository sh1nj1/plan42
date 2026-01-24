require_relative "lib/collavre/version"

Gem::Specification.new do |spec|
  spec.name        = "collavre"
  spec.version     = Collavre::VERSION
  spec.authors     = [ "Collavre Team" ]
  spec.email       = [ "team@collavre.com" ]
  spec.homepage    = "https://collavre.com"
  spec.summary     = "Core engine for Collavre platform"
  spec.description = "Provides knowledge management, task management, and collaboration features"
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 8.0"
  spec.add_dependency "closure_tree"
  spec.add_dependency "view_component"
end
