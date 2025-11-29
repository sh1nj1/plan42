# frozen_string_literal: true

# FastMcp - Model Context Protocol for Rails
# This initializer sets up the MCP middleware in your Rails application.
#
# In Rails applications, you can use:
# - ActionTool::Base as an alias for FastMcp::Tool
# - ActionResource::Base as an alias for FastMcp::Resource
#
# All your tools should inherit from ApplicationTool which already uses ActionTool::Base,
# and all your resources should inherit from ApplicationResource which uses ActionResource::Base.

# Mount the MCP middleware in your Rails application
# You can customize the options below to fit your needs.
require "fast_mcp"
require_relative "../../lib/mcp_oauth_middleware"

puts "FastMcp: Initializer loaded"

FastMcp.mount_in_rails(
  Rails.application,
  name: Rails.application.class.module_parent_name.underscore.dasherize,
  version: "1.0.0",
  path_prefix: "/mcp", # This is the default path prefix
  messages_route: "messages", # This is the default route for the messages endpoint
  sse_route: "sse", # This is the default route for the SSE endpoint
  # Add allowed origins below, it defaults to Rails.application.config.hosts
  # allowed_origins: ['localhost', '127.0.0.1', '[::1]', 'example.com', /.*\.example\.com/],
  localhost_only: false, # Set to false to allow connections from other hosts
  # whitelist specific ips to if you want to run on localhost and allow connections from other IPs
  # allowed_ips: ['127.0.0.1', '::1'],
  # authenticate: true,       # Uncomment to enable authentication
  # auth_token: 'your-token', # Required if authenticate: true
) do |server|
  puts "FastMcp: Inside mount block"
  Rails.application.config.after_initialize do
    puts "FastMcp: Inside after_initialize"
    # Force load tools and resources to ensure descendants are populated
    tool_files = Dir[Rails.root.join("app", "tools", "**", "*.rb")]
    puts "FastMcp: Found tool files: #{tool_files}"
    tool_files.each { |f| require f }

    resource_files = Dir[Rails.root.join("app", "resources", "**", "*.rb")]
    puts "FastMcp: Found resource files: #{resource_files}"
    resource_files.each { |f| require f }

    puts "FastMcp: ApplicationTool descendants: #{ApplicationTool.descendants.map(&:name)}"

    # FastMcp will automatically discover and register:
    # - All classes that inherit from ApplicationTool (which uses ActionTool::Base)
    # - All classes that inherit from ApplicationResource (which uses ActionResource::Base)
    server.register_tools(*ApplicationTool.descendants)
    server.register_resources(*ApplicationResource.descendants)

    puts "FastMcp: Server tools: #{server.instance_variable_get(:@tools).keys}"
    # alternatively, you can register tools and resources manually:
    # server.register_tool(MyTool)
    # server.register_resource(MyResource)
  end
end

# Insert the OAuth middleware to protect /mcp endpoints
Rails.application.config.middleware.insert_before FastMcp::Transports::RackTransport, McpOauthMiddleware
