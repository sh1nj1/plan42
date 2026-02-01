require_relative "lib/collavre_openclaw/version"

Gem::Specification.new do |spec|
  spec.name        = "collavre_openclaw"
  spec.version     = CollavreOpenclaw::VERSION
  spec.authors     = ["Collavre"]
  spec.email       = ["support@collavre.com"]
  spec.homepage    = "https://github.com/sh1nj1/plan42"
  spec.summary     = "OpenClaw AI Gateway integration for Collavre"
  spec.description = "Enables AI agents in Collavre to use OpenClaw as their LLM backend"
  spec.license     = "AGPL-3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/sh1nj1/plan42"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "LICENSE", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 8.0"
  spec.add_dependency "faraday", ">= 2.0"
end
