require_relative "lib/collavre_github/version"

Gem::Specification.new do |spec|
  spec.name        = "collavre_github"
  spec.version     = CollavreGithub::VERSION
  spec.authors     = [ "Collavre" ]
  spec.email       = [ "support@collavre.com" ]
  spec.homepage    = "https://collavre.com"
  spec.summary     = "GitHub integration for Collavre"
  spec.description = "Plugin engine to connect Collavre creatives with GitHub repositories and receive webhook events."
  spec.license     = "AGPL"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/sh1nj1/plan42"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 8.0"
  spec.add_dependency "collavre"
  spec.add_dependency "octokit"
end
