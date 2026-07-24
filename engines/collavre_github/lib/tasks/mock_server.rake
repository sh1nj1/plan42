# frozen_string_literal: true

namespace :collavre_github do
  desc "Start GitHub API mock server for development (port: GITHUB_MOCK_PORT, default 4567)"
  task :mock_server do
    load CollavreGithub::Engine.root.join("script/mock_server.rb")
  end
end
