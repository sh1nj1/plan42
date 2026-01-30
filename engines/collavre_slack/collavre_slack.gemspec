require_relative "lib/collavre_slack/version"

Gem::Specification.new do |spec|
  spec.name        = "collavre_slack"
  spec.version     = CollavreSlack::VERSION
  spec.authors     = [ "Collavre" ]
  spec.email       = [ "support@collavre.com" ]
  spec.homepage    = "https://collavre.com"
  spec.summary     = "Slack integration for Collavre"
  spec.description = "Plugin engine to connect Collavre creatives with Slack channels and sync chat messages."
  spec.license     = "AGPL"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/sh1nj1/plan42"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 8.0"
  spec.add_dependency "collavre"
  spec.add_dependency "faraday"
  spec.add_dependency "faraday-retry"
end
