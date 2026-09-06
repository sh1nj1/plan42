# frozen_string_literal: true

namespace :collavre_notion do
  desc "Start Notion API mock server for development (port: NOTION_MOCK_PORT, default 4568)"
  task :mock_server do
    load CollavreNotion::Engine.root.join("script/mock_server.rb")
  end
end
