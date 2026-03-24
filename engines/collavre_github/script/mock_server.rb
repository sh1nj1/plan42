#!/usr/bin/env ruby
# frozen_string_literal: true

# GitHub API Mock Server for development
# Provides fake responses for Octokit API calls so the GitHub integration
# UI can be previewed without real GitHub credentials.
#
# Usage:
#   ruby engines/collavre_github/script/mock_server.rb
#   # or via rake:
#   bin/rails collavre_github:mock_server
#
# Set GITHUB_MOCK_PORT to change the port (default: 4567)

require "socket"
require "json"
require "uri"

PORT = Integer(ENV.fetch("GITHUB_MOCK_PORT", 4567))

# --- Mock Data ---

MOCK_USER = {
  id: 12345,
  login: "dev-user",
  name: "Dev User",
  avatar_url: "https://avatars.githubusercontent.com/u/12345",
  type: "User"
}.freeze

MOCK_ORGS = [
  { id: 100, login: "acme-corp", name: "ACME Corporation", type: "Organization" },
  { id: 101, login: "startup-inc", name: "Startup Inc", type: "Organization" }
].freeze

MOCK_USER_REPOS = [
  { id: 1, name: "my-app", full_name: "dev-user/my-app", private: false },
  { id: 2, name: "dotfiles", full_name: "dev-user/dotfiles", private: true },
  { id: 3, name: "blog", full_name: "dev-user/blog", private: false }
].freeze

MOCK_ORG_REPOS = {
  "acme-corp" => [
    { id: 10, name: "backend", full_name: "acme-corp/backend", private: true },
    { id: 11, name: "frontend", full_name: "acme-corp/frontend", private: true },
    { id: 12, name: "docs", full_name: "acme-corp/docs", private: false },
    { id: 13, name: "infrastructure", full_name: "acme-corp/infrastructure", private: true }
  ],
  "startup-inc" => [
    { id: 20, name: "product", full_name: "startup-inc/product", private: true },
    { id: 21, name: "landing-page", full_name: "startup-inc/landing-page", private: false }
  ]
}.freeze

# --- Router ---

def route(method, path, query_params)
  hooks_pattern = %r{\A/repos/[^/]+/[^/]+/hooks\z}
  org_repos_pattern = %r{\A/orgs/([^/]+)/repos\z}

  if method == "GET" && path == "/user"
    [ 200, MOCK_USER ]
  elsif method == "GET" && path == "/user/orgs"
    [ 200, MOCK_ORGS ]
  elsif method == "GET" && path == "/user/repos"
    [ 200, MOCK_USER_REPOS ]
  elsif method == "GET" && (m = path.match(org_repos_pattern))
    repos = MOCK_ORG_REPOS[m[1]]
    repos ? [ 200, repos ] : [ 404, { message: "Not Found" } ]
  elsif method == "GET" && path.match?(hooks_pattern)
    [ 200, [] ]
  elsif method == "POST" && path.match?(hooks_pattern)
    [ 201, { id: rand(10_000), active: true, config: {} } ]
  else
    [ 404, { message: "Mock endpoint not found: #{method} #{path}" } ]
  end
end

# --- HTTP Server ---

def parse_request(client)
  request_line = client.gets
  return nil unless request_line

  method, full_path, = request_line.split(" ")
  uri = URI.parse(full_path)
  path = uri.path
  query_params = URI.decode_www_form(uri.query || "").to_h

  # Read headers
  headers = {}
  while (line = client.gets) && line != "\r\n"
    key, value = line.split(": ", 2)
    headers[key.downcase] = value&.strip
  end

  # Read body if present
  body = nil
  if headers["content-length"]
    body = client.read(headers["content-length"].to_i)
  end

  { method: method, path: path, query: query_params, headers: headers, body: body }
end

def send_response(client, status, body)
  json_body = body.to_json
  status_text = { 200 => "OK", 201 => "Created", 404 => "Not Found" }[status] || "OK"

  client.print "HTTP/1.1 #{status} #{status_text}\r\n"
  client.print "Content-Type: application/json\r\n"
  client.print "Content-Length: #{json_body.bytesize}\r\n"
  client.print "Access-Control-Allow-Origin: *\r\n"
  client.print "Access-Control-Allow-Methods: GET, POST, PATCH, DELETE, OPTIONS\r\n"
  client.print "Access-Control-Allow-Headers: *\r\n"
  client.print "Connection: close\r\n"
  client.print "\r\n"
  client.print json_body
end

# --- Main ---

server = TCPServer.new("0.0.0.0", PORT)
puts "🐙 GitHub API Mock Server running on http://localhost:#{PORT}"
puts "   Set GITHUB_API_ENDPOINT=http://localhost:#{PORT} in .env.development"
puts "   Press Ctrl+C to stop"
puts ""
puts "   Available endpoints:"
puts "     GET  /user           → mock user profile"
puts "     GET  /user/orgs      → #{MOCK_ORGS.size} organizations"
puts "     GET  /user/repos     → #{MOCK_USER_REPOS.size} user repositories"
MOCK_ORG_REPOS.each do |org, repos|
  puts "     GET  /orgs/#{org}/repos → #{repos.size} repositories"
end
puts "     GET  /repos/:owner/:repo/hooks → empty hooks"
puts "     POST /repos/:owner/:repo/hooks → created hook"
puts ""

loop do
  client = server.accept
  Thread.new(client) do |c|
    begin
      req = parse_request(c)
      next unless req

      # Handle CORS preflight
      if req[:method] == "OPTIONS"
        send_response(c, 200, {})
      else
        status, body = route(req[:method], req[:path], req[:query])
        send_response(c, status, body)
        puts "  #{req[:method]} #{req[:path]} → #{status}"
      end
    rescue StandardError => e
      puts "  ERROR: #{e.message}"
    ensure
      c.close
    end
  end
rescue Interrupt
  puts "\n🛑 Mock server stopped"
  server.close
  break
end
