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

  # Core dependencies - required for the engine to function
  spec.add_dependency "rails", ">= 8.0"
  spec.add_dependency "closure_tree"           # Hierarchical tree structure for creatives
  spec.add_dependency "view_component"         # ViewComponent for reusable UI components
  spec.add_dependency "turbo-rails"            # Hotwire Turbo for real-time updates
  spec.add_dependency "stimulus-rails"         # Stimulus controllers for JavaScript

  # Authentication
  spec.add_dependency "bcrypt"                 # Password hashing for users

  # AI/LLM features
  spec.add_dependency "ruby_llm"               # LLM integration for AI agents
  spec.add_dependency "liquid"                 # Liquid templates for AI system prompts

  # Integrations
  spec.add_dependency "httparty"               # HTTP client for link previews and APIs
  spec.add_dependency "nokogiri"               # HTML/XML parsing

  # Optional dependencies - add to your Gemfile if using these features:
  #
  # Push notifications:
  #   gem "fcm"
  #   gem "google-apis-fcm_v1"
  #
  # Google Calendar integration:
  #   gem "google-apis-calendar_v3"
  #   gem "googleauth"
  #
  # GitHub integration:
  #   gem "octokit"
  #
  # PPT/PPTX import:
  #   gem "rubyzip"
end
