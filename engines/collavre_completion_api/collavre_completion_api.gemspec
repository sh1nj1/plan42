require_relative "lib/collavre_completion_api/version"

Gem::Specification.new do |spec|
  spec.name        = "collavre_completion_api"
  spec.version     = CollavreCompletionApi::VERSION
  spec.authors     = [ "Collavre" ]
  spec.email       = [ "support@collavre.com" ]
  spec.homepage    = "https://collavre.com"
  spec.summary     = "OpenAI-compatible chat completions API for Collavre"
  spec.description = "Plugin engine providing OpenAI-compatible /v1/chat/completions and /v1/models endpoints using Collavre AI agents with context injection."
  spec.license     = "AGPL"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/sh1nj1/plan42"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,lib}/**/*", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 8.0"
  spec.add_dependency "collavre"
  spec.add_dependency "doorkeeper"
end
