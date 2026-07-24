require_relative "lib/collavre_plan/version"

Gem::Specification.new do |spec|
  spec.name        = "collavre_plan"
  spec.version     = CollavrePlan::VERSION
  spec.authors     = [ "Collavre" ]
  spec.email       = [ "support@collavre.com" ]
  spec.homepage    = "https://collavre.com"
  spec.summary     = "Plan feature for Collavre"
  spec.description = "Plugin engine providing plan/timeline management for Collavre creatives"
  spec.license     = "AGPL"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/sh1nj1/plan42"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 8.0"
  spec.add_dependency "collavre"
end
