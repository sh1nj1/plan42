#!/usr/bin/env ruby
# frozen_string_literal: true

# Notion API Mock Server for development
# Provides fake responses for Notion API calls so the Notion integration
# UI can be previewed without real Notion credentials.
#
# Usage:
#   ruby engines/collavre_notion/script/mock_server.rb
#   # or via rake:
#   bin/rails collavre_notion:mock_server
#
# Set NOTION_MOCK_PORT to change the port (default: 4568)

require "socket"
require "json"
require "uri"
require "securerandom"

PORT = Integer(ENV.fetch("NOTION_MOCK_PORT", 4568))

# --- Mock Data ---

MOCK_BOT = {
  "object" => "user",
  "id" => SecureRandom.uuid,
  "type" => "bot",
  "bot" => {
    "owner" => { "type" => "workspace", "workspace" => true },
    "workspace_name" => "Dev Workspace"
  },
  "name" => "Collavre Integration",
  "avatar_url" => nil
}.freeze

MOCK_PAGES = [
  {
    "object" => "page",
    "id" => "page-001-#{SecureRandom.hex(4)}",
    "url" => "https://www.notion.so/Dev-Workspace/Project-Notes-abc123",
    "parent" => { "type" => "workspace", "workspace" => true },
    "properties" => {
      "title" => { "title" => [ { "text" => { "content" => "Project Notes" } } ] }
    }
  },
  {
    "object" => "page",
    "id" => "page-002-#{SecureRandom.hex(4)}",
    "url" => "https://www.notion.so/Dev-Workspace/Meeting-Notes-def456",
    "parent" => { "type" => "workspace", "workspace" => true },
    "properties" => {
      "title" => { "title" => [ { "text" => { "content" => "Meeting Notes" } } ] }
    }
  },
  {
    "object" => "page",
    "id" => "page-003-#{SecureRandom.hex(4)}",
    "url" => "https://www.notion.so/Dev-Workspace/Sprint-Backlog-ghi789",
    "parent" => { "type" => "workspace", "workspace" => true },
    "properties" => {
      "title" => { "title" => [ { "text" => { "content" => "Sprint Backlog" } } ] }
    }
  },
  {
    "object" => "page",
    "id" => "page-004-#{SecureRandom.hex(4)}",
    "url" => "https://www.notion.so/Dev-Workspace/Design-System-jkl012",
    "parent" => { "type" => "workspace", "workspace" => true },
    "properties" => {
      "title" => { "title" => [ { "text" => { "content" => "Design System" } } ] }
    }
  }
].freeze

# Store created pages in memory
created_pages = {}

# --- Router ---

def route(method, path, body, created_pages) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/MethodLength
  case [ method, path ]
  when [ "GET", "/v1/users/me" ]
    [ 200, MOCK_BOT ]
  when [ "POST", "/v1/search" ]
    query = body&.dig("query")&.downcase
    results = MOCK_PAGES.dup
    results.concat(created_pages.values)
    if query && !query.empty?
      results = results.select do |p|
        title = p.dig("properties", "title", "title", 0, "text", "content")&.downcase
        title&.include?(query)
      end
    end
    [ 200, { "object" => "list", "results" => results, "has_more" => false, "next_cursor" => nil } ]
  when [ "POST", "/v1/pages" ]
    # Create page
    page_id = SecureRandom.uuid
    title = body&.dig("properties", "title", "title", 0, "text", "content") || "Untitled"
    page = {
      "object" => "page",
      "id" => page_id,
      "url" => "https://www.notion.so/Dev-Workspace/#{title.tr(' ', '-')}-#{SecureRandom.hex(4)}",
      "parent" => body&.dig("parent") || { "type" => "workspace", "workspace" => true },
      "properties" => body&.dig("properties") || {}
    }
    created_pages[page_id] = page
    [ 200, page ]
  else
    # Dynamic routes
    page_match = path.match(%r{\A/v1/pages/([^/]+)\z})
    blocks_match = path.match(%r{\A/v1/blocks/([^/]+)/children\z})
    block_delete_match = path.match(%r{\A/v1/blocks/([^/]+)\z})

    if method == "GET" && page_match
      page_id = page_match[1]
      page = MOCK_PAGES.find { |p| p["id"] == page_id } || created_pages[page_id]
      page ? [ 200, page ] : [ 404, { "object" => "error", "status" => 404, "message" => "Not found" } ]
    elsif method == "GET" && blocks_match
      [ 200, { "object" => "list", "results" => [], "has_more" => false, "next_cursor" => nil } ]
    elsif method == "PATCH" && blocks_match
      # Append blocks
      children = body&.dig("children") || []
      results = children.map { |_b| { "id" => SecureRandom.uuid, "object" => "block" } }
      [ 200, { "object" => "list", "results" => results, "has_more" => false } ]
    elsif method == "PATCH" && page_match
      # Update page
      page_id = page_match[1]
      page = MOCK_PAGES.find { |p| p["id"] == page_id } || created_pages[page_id]
      page ? [ 200, page ] : [ 404, { "object" => "error", "status" => 404, "message" => "Not found" } ]
    elsif method == "DELETE" && block_delete_match
      [ 200, { "object" => "block", "id" => block_delete_match[1], "archived" => true } ]
    else
      [ 404, { "object" => "error", "status" => 404, "message" => "Mock endpoint not found: #{method} #{path}" } ]
    end
  end
end

# --- HTTP Server ---

def parse_request(client)
  request_line = client.gets
  return nil unless request_line

  method, full_path, = request_line.split(" ")
  uri = URI.parse(full_path)
  path = uri.path

  headers = {}
  while (line = client.gets) && line != "\r\n"
    key, value = line.split(": ", 2)
    headers[key.downcase] = value&.strip
  end

  body = nil
  if headers["content-length"]
    raw = client.read(headers["content-length"].to_i)
    body = JSON.parse(raw) rescue nil
  end

  { method: method, path: path, headers: headers, body: body }
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
created_pages = {}

puts "📝 Notion API Mock Server running on http://localhost:#{PORT}"
puts "   Set NOTION_API_ENDPOINT=http://localhost:#{PORT}/v1 in .env.development"
puts "   Press Ctrl+C to stop"
puts ""
puts "   Available endpoints:"
puts "     GET  /v1/users/me              → mock bot user"
puts "     POST /v1/search                → #{MOCK_PAGES.size} pages (filterable)"
puts "     POST /v1/pages                 → create page"
puts "     GET  /v1/pages/:id             → get page"
puts "     PATCH /v1/pages/:id            → update page"
puts "     GET  /v1/blocks/:id/children   → empty blocks"
puts "     PATCH /v1/blocks/:id/children  → append blocks"
puts "     DELETE /v1/blocks/:id          → delete block"
puts ""

loop do
  client = server.accept
  Thread.new(client) do |c|
    begin
      req = parse_request(c)
      next unless req

      if req[:method] == "OPTIONS"
        send_response(c, 200, {})
      else
        status, body = route(req[:method], req[:path], req[:body], created_pages)
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
