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
require "digest"
require "base64"

PORT = Integer(ENV.fetch("GITHUB_MOCK_PORT", 4567))

# --- Mock Content Directory ---
# Scan a real directory for .md files to serve as mock GitHub repo content.
# Defaults to the project's docs/ directory.
PROJECT_ROOT = ENV.fetch("GITHUB_MOCK_PROJECT_ROOT") {
  File.expand_path("../../..", __dir__) # project root (script → collavre_github → engines → project)
}

# Scan only these subdirectories for .md files (fast, avoids node_modules/vendor)
SCAN_DIRS = %w[.collavre-docs docs engines skills].freeze
SCAN_ROOT_FILES = %w[README.md AGENTS.md].freeze

# --- Build mock file tree from real directory ---

def build_mock_tree(base_dir)
  entries = []
  return entries unless File.directory?(base_dir)

  # Collect all .md files from specific subdirectories + root files
  all_md = []
  SCAN_ROOT_FILES.each do |f|
    all_md << f if File.exist?(File.join(base_dir, f))
  end
  SCAN_DIRS.each do |subdir|
    dir = File.join(base_dir, subdir)
    next unless File.directory?(dir)
    Dir.glob("**/*.md", base: dir).sort.each do |rel|
      all_md << "#{subdir}/#{rel}"
    end
  end
  all_md.sort!

  all_md.each do |relative_path|
    full_path = File.join(base_dir, relative_path)
    content = File.read(full_path, encoding: "UTF-8")
    blob_sha = Digest::SHA1.hexdigest("blob #{content.bytesize}\0#{content}")

    # Add directory entries (tree type)
    parts = relative_path.split("/")
    parts[0...-1].each_with_index do |_part, i|
      dir_path = parts[0..i].join("/")
      unless entries.any? { |e| e[:path] == dir_path && e[:type] == "tree" }
        entries << { path: dir_path, type: "tree", mode: "040000", sha: Digest::SHA1.hexdigest(dir_path) }
      end
    end

    entries << {
      path: relative_path,
      type: "blob",
      mode: "100644",
      sha: blob_sha,
      size: content.bytesize
    }
  end
  entries
end

MOCK_TREE = build_mock_tree(PROJECT_ROOT)
MOCK_TREE_SHA = Digest::SHA1.hexdigest("tree-#{PROJECT_ROOT}")
MOCK_COMMIT_SHA = Digest::SHA1.hexdigest("commit-mock-main")

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
  { id: 1, name: "my-app", full_name: "dev-user/my-app", private: false, default_branch: "main" },
  { id: 2, name: "dotfiles", full_name: "dev-user/dotfiles", private: true, default_branch: "main" },
  { id: 3, name: "blog", full_name: "dev-user/blog", private: false, default_branch: "main" }
].freeze

MOCK_ORG_REPOS = {
  "acme-corp" => [
    { id: 10, name: "backend", full_name: "acme-corp/backend", private: true, default_branch: "main" },
    { id: 11, name: "frontend", full_name: "acme-corp/frontend", private: true, default_branch: "main" },
    { id: 12, name: "docs", full_name: "acme-corp/docs", private: false, default_branch: "main" },
    { id: 13, name: "infrastructure", full_name: "acme-corp/infrastructure", private: true, default_branch: "main" }
  ],
  "startup-inc" => [
    { id: 20, name: "product", full_name: "startup-inc/product", private: true, default_branch: "main" },
    { id: 21, name: "landing-page", full_name: "startup-inc/landing-page", private: false, default_branch: "main" }
  ]
}.freeze

ALL_REPOS = (MOCK_USER_REPOS + MOCK_ORG_REPOS.values.flatten).each_with_object({}) { |r, h| h[r[:full_name]] = r }

# --- Router ---

def route(method, path, query_params)
  hooks_pattern = %r{\A/repos/[^/]+/[^/]+/hooks\z}
  org_repos_pattern = %r{\A/orgs/([^/]+)/repos\z}
  repo_pattern = %r{\A/repos/([^/]+/[^/]+)\z}
  ref_pattern = %r{\A/repos/([^/]+/[^/]+)/git/refs/heads/(.+)\z}
  tree_pattern = %r{\A/repos/([^/]+/[^/]+)/git/trees/(.+)\z}
  contents_pattern = %r{\A/repos/([^/]+/[^/]+)/contents/(.+)\z}

  if method == "GET" && path == "/user"
    [ 200, MOCK_USER ]
  elsif method == "GET" && path == "/user/orgs"
    [ 200, MOCK_ORGS ]
  elsif method == "GET" && path == "/user/repos"
    [ 200, MOCK_USER_REPOS ]
  elsif method == "GET" && (m = path.match(org_repos_pattern))
    repos = MOCK_ORG_REPOS[m[1]]
    repos ? [ 200, repos ] : [ 404, { message: "Not Found" } ]

  # GET /repos/:owner/:repo — repository info (default_branch)
  elsif method == "GET" && (m = path.match(repo_pattern))
    repo = ALL_REPOS[m[1]]
    repo ? [ 200, repo ] : [ 200, { full_name: m[1], default_branch: "main" } ]

  # GET /repos/:owner/:repo/git/refs/heads/:branch — git ref (commit SHA)
  elsif method == "GET" && (m = path.match(ref_pattern))
    [ 200, { ref: "refs/heads/#{m[2]}", object: { sha: MOCK_COMMIT_SHA, type: "commit" } } ]

  # GET /repos/:owner/:repo/git/trees/:sha — recursive tree
  elsif method == "GET" && (m = path.match(tree_pattern))
    [ 200, { sha: m[2], tree: MOCK_TREE, truncated: false } ]

  # GET /repos/:owner/:repo/contents/:path — file content (base64)
  elsif method == "GET" && (m = path.match(contents_pattern))
    file_path = URI.decode_www_form_component(m[2])
    full_path = File.join(PROJECT_ROOT, file_path)
    if File.file?(full_path)
      content = File.read(full_path, encoding: "UTF-8")
      sha = Digest::SHA1.hexdigest("blob #{content.bytesize}\0#{content}")
      [ 200, {
        name: File.basename(file_path),
        path: file_path,
        sha: sha,
        size: content.bytesize,
        encoding: "base64",
        content: Base64.strict_encode64(content),
        type: "file"
      } ]
    else
      [ 404, { message: "Not Found: #{file_path}" } ]
    end

  elsif method == "GET" && path.match?(hooks_pattern)
    [ 200, [] ]
  elsif method == "POST" && path.match?(hooks_pattern)
    [ 201, { id: rand(10_000), active: true, config: {} } ]
  elsif method == "PATCH" && path.match?(%r{\A/repos/[^/]+/[^/]+/hooks/\d+\z})
    [ 200, { id: path.split("/").last.to_i, active: true, config: {} } ]
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
md_count = MOCK_TREE.count { |e| e[:type] == "blob" }
puts "🐙 GitHub API Mock Server running on http://localhost:#{PORT}"
puts "   Set GITHUB_API_ENDPOINT=http://localhost:#{PORT} in .env.development"
puts "   Press Ctrl+C to stop"
puts ""
puts "   Content directory: #{PROJECT_ROOT}"
puts "   Markdown files:    #{md_count}"
puts ""
puts "   Available endpoints:"
puts "     GET  /user           → mock user profile"
puts "     GET  /user/orgs      → #{MOCK_ORGS.size} organizations"
puts "     GET  /user/repos     → #{MOCK_USER_REPOS.size} user repositories"
MOCK_ORG_REPOS.each do |org, repos|
  puts "     GET  /orgs/#{org}/repos → #{repos.size} repositories"
end
puts "     GET  /repos/:owner/:repo           → repository info (default_branch)"
puts "     GET  /repos/:owner/:repo/git/refs  → git ref (commit SHA)"
puts "     GET  /repos/:owner/:repo/git/trees → #{md_count} .md files tree"
puts "     GET  /repos/:owner/:repo/contents  → file content (base64)"
puts "     GET  /repos/:owner/:repo/hooks     → empty hooks"
puts "     POST /repos/:owner/:repo/hooks     → created hook"
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
