# frozen_string_literal: true

require "test_helper"
require "open3"
require "socket"
require "tmpdir"

class CollavreToolAuthoringTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("engines/collavre/skills/collavre/scripts/collavre").to_s

  teardown do
    Tools::MetaToolWriteService.new.delete_tool("authored_probe")
    Tools.send(:remove_const, :AuthoredProbeService) if Tools.const_defined?(:AuthoredProbeService, false)
  end

  test "scaffolded tool becomes a runnable tool once its Creative is approved" do
    user = users(:one)
    source, _err, status = cli("tool", "scaffold", "--name", "authored_probe", "--desc", 'Probe "quoted" #{x}')
    assert_predicate status, :success?

    markdown = dry_run(source, "--parent", "1")
    assert_match(/\A# authored_probe\n\nProbe "quoted" #\{x\}\n\n```ruby\nmodule Tools\n/, markdown)

    target = Creative.create!(user: user, description: "Target")
    host = Creative.new(user: user)
    host.content_type_input = "markdown"
    host.markdown_source = markdown
    host.save!
    Collavre::McpService.new.update_from_creative(host)

    tool = McpTool.find_by!(name: "authored_probe")
    assert_equal host, tool.creative
    assert_not tool.active?
    assert_equal source.strip, tool.source_code.strip

    tool.approve!
    Current.set(user: user) do
      result = Tools::MetaToolService.new.call(
        action: "run", tool_name: "authored_probe", arguments: { creative_id: target.id }
      )
      assert_equal({ success: true, id: target.id, progress: target.progress }, result[:result])
    end
  end

  test "source containing backticks gets a longer fence that round-trips" do
    source = scaffold.sub("    def call", "    MARK = \"```\"\n\n    def call")
    markdown = dry_run(source, "--parent", "1", "--title", "Probe tool")

    assert_match(/\A# Probe tool\n/, markdown)
    assert_includes markdown, "````ruby\n"
    assert markdown.end_with?("\n````\n")
  end

  test "reads single-quoted metadata and flattens escaped newlines in the summary" do
    source = scaffold
      .sub('tool_name "authored_probe"', "tool_name 'authored_probe'")
      .sub('tool_description "Probe"', 'tool_description "Line one\nline two"')
    markdown = dry_run(source, "--parent", "1")

    assert_match(/\A# authored_probe\n\nLine one line two\n\n/, markdown)
  end

  test "rejects invalid sources and incomplete commands without contacting the server" do
    Dir.mktmpdir do |dir|
      bad = File.join(dir, "bad.rb")
      File.write(bad, "class Foo\n  tool_name \"BadName\"\nend\n")
      _out, err, status = cli("tool", "create", "--parent", "1", "--file", bad, home: dir)
      assert_not_predicate status, :success?
      assert_includes err, "Missing `extend ToolMeta`"
      assert_includes err, 'tool_name "BadName" must be snake_case'
      assert_includes err, "Missing `tool_description"
      assert_includes err, "Tools namespace"
      assert_includes err, "Missing Sorbet `sig`"
      assert_includes err, "Missing `def call"

      empty = File.join(dir, "empty.rb")
      File.write(empty, "  \n")
      _out, err, = cli("tool", "update", "7", "--file", empty, home: dir)
      assert_includes err, "Tool source is empty"

      no_name = File.join(dir, "no_name.rb")
      File.write(no_name, "extend ToolMeta\n")
      _out, err, = cli("tool", "create", "--parent", "1", "--file", no_name, home: dir)
      assert_includes err, 'Missing `tool_name "snake_case_name"`'

      [
        [ %w[tool scaffold], "--name must be snake_case" ],
        [ %w[tool scaffold --name BadName], "--name must be snake_case" ],
        [ %w[tool create --file] + [ bad ], "Usage: collavre tool create" ],
        [ %w[tool update --file] + [ bad ], "Usage: collavre tool update" ],
        [ %w[tool create --parent 1 --file /missing/tool.rb], "File not found" ]
      ].each do |argv, message|
        _out, err, status = cli(*argv, home: dir)
        assert_not_predicate status, :success?, argv.join(" ")
        assert_includes err, message
      end

      out, = cli("tool", "help", home: dir)
      assert_includes out, "scaffold --name <snake_name>"
    end
  end

  test "scaffold without a description leaves a TODO summary" do
    assert_includes scaffold(desc: nil), 'tool_description "TODO: describe what authored_probe does"'
  end

  test "create checks for an existing tool, then creates the Creative" do
    with_fake_mcp(get_text: '{"error":"Tool not found: authored_probe"}') do |home, calls|
      out, err, status = cli_with_source(home, "create", "--parent", "42")
      assert_predicate status, :success?, err
      assert_equal %w[meta_tool creative_create_service], calls.map { |c| c["name"] }
      assert_equal({ "action" => "get", "tool_name" => "authored_probe" }, calls.first["arguments"])
      assert_equal 42, calls.last.dig("arguments", "parent_id")
      assert_match(/\A# authored_probe\n/, calls.last.dig("arguments", "description"))
      assert_includes out, '"ok": true'
      assert_includes err, "pending approval"
    end
  end

  test "create refuses a tool name that is already registered" do
    with_fake_mcp(get_text: '{"name":"authored_probe"}') do |home, calls|
      _out, err, status = cli_with_source(home, "create", "--parent", "42")
      assert_not_predicate status, :success?
      assert_includes err, 'Tool "authored_probe" already exists'
      assert_equal %w[meta_tool], calls.map { |c| c["name"] }
    end
  end

  test "update replaces the tool Creative description" do
    with_fake_mcp(get_text: "") do |home, calls|
      _out, err, status = cli_with_source(home, "update", "77")
      assert_predicate status, :success?, err
      assert_equal %w[creative_update_service], calls.map { |c| c["name"] }
      assert_equal 77, calls.first.dig("arguments", "id")
      assert_includes calls.first.dig("arguments", "description"), "```ruby\nmodule Tools\n"
    end
  end

  private

  def cli(*argv, home: Dir.tmpdir)
    Open3.capture3({ "HOME" => home }, "node", SCRIPT, *argv)
  end

  def scaffold(desc: "Probe")
    argv = [ "tool", "scaffold", "--name", "authored_probe" ]
    argv += [ "--desc", desc ] if desc
    cli(*argv).first
  end

  def dry_run(source, *argv)
    Dir.mktmpdir do |dir|
      file = File.join(dir, "tool.rb")
      File.write(file, source)
      out, err, status = cli("tool", "create", "--file", file, "--dry-run", *argv, home: dir)
      assert_predicate status, :success?, err
      out
    end
  end

  def cli_with_source(home, sub, *argv)
    file = File.join(home, "tool.rb")
    File.write(file, scaffold)
    positional = sub == "update" ? [ argv.shift ] : []
    cli("tool", sub, *positional, "--file", file, *argv, home: home)
  end

  # Minimal MCP SSE endpoint: GET /mcp/sse announces the messages URL, and each
  # POSTed tools/call is answered on the SSE stream.
  def with_fake_mcp(get_text:)
    server = TCPServer.new("127.0.0.1", 0)
    calls = []
    sse = Queue.new
    thread = Thread.new do
      loop do
        socket = server.accept
        Thread.new(socket) { |s| serve_fake_mcp(s, sse, calls, get_text) }
      end
    rescue IOError
      nil
    end

    Dir.mktmpdir do |home|
      config_dir = File.join(home, ".config", "collavre")
      FileUtils.mkdir_p(config_dir)
      File.write(File.join(config_dir, "config.json"),
        { url: "http://127.0.0.1:#{server.addr[1]}", token: "t" }.to_json)
      yield home, calls
    end
  ensure
    server&.close
    thread&.kill
  end

  def serve_fake_mcp(socket, sse, calls, get_text)
    request_line = socket.gets
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      key, value = line.split(":", 2)
      headers[key.downcase] = value.strip
    end

    if request_line.start_with?("GET /mcp/sse")
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n")
      socket.write("data: /mcp/messages?session=1\n\n")
      sse << socket
    else
      body = JSON.parse(read_body(socket, headers))
      params = body["params"]
      calls << params
      socket.write("HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      socket.close
      text = params["name"] == "meta_tool" ? get_text : '{"ok":true}'
      stream = sse.pop
      sse << stream
      stream.write("data: #{{ jsonrpc: '2.0', id: body['id'], result: { content: [ { type: 'text', text: text } ] } }.to_json}\n\n")
    end
  rescue IOError, Errno::EPIPE, Errno::ECONNRESET
    nil
  end

  # Node sends request bodies without Content-Length as chunked encoding.
  def read_body(socket, headers)
    return socket.read(headers["content-length"].to_i) if headers["content-length"]

    body = +""
    while (size = socket.gets.to_i(16)).positive?
      body << socket.read(size)
      socket.gets
    end
    socket.gets
    body
  end
end
