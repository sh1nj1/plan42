# frozen_string_literal: true

require "test_helper"
require "open3"
require "socket"
require "tmpdir"

class CollavreToolAuthoringTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("engines/collavre/skills/collavre/scripts/collavre").to_s
  EVAL_STARTED = Queue.new
  EVAL_GATE = Queue.new

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

  NOT_FOUND = '{"error":"Tool not found: authored_probe"}'

  test "create checks for an existing tool, then creates the Creative" do
    with_fake_mcp("meta_tool" => NOT_FOUND) do |home, calls|
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
    with_fake_mcp("meta_tool" => '{"name":"authored_probe"}') do |home, calls|
      _out, err, status = cli_with_source(home, "create", "--parent", "42")
      assert_not_predicate status, :success?
      assert_includes err, 'Tool "authored_probe" already exists'
      assert_equal %w[meta_tool], calls.map { |c| c["name"] }
    end
  end

  test "create fails when the server rejects the Creative" do
    responses = { "meta_tool" => NOT_FOUND, "creative_create_service" => '{"error":"Parent Creative not found","id":42}' }
    with_fake_mcp(responses) do |home, _calls|
      out, err, status = cli_with_source(home, "create", "--parent", "42")
      assert_not_predicate status, :success?
      assert_includes out, "Parent Creative not found"
      assert_includes err, "Error: Parent Creative not found"
      assert_not_includes err, "pending approval"
    end
  end

  test "create reports a draft change set instead of a tool approval under review policy" do
    draft = '{"success":true,"status":"pending_review","pending_review":true,"change_set_id":9}'
    with_fake_mcp("meta_tool" => NOT_FOUND, "creative_create_service" => draft) do |home, _calls|
      _out, err, status = cli_with_source(home, "create", "--parent", "42")
      assert_predicate status, :success?, err
      assert_includes err, "waiting for change set 9 to be reviewed"
      assert_not_includes err, "pending approval"
    end
  end

  test "update keeps the Creative's own tool name without a registry check" do
    with_fake_mcp("creative_retrieval_service" => owner(77, "authored_probe")) do |home, calls|
      _out, err, status = cli_with_source(home, "update", "77")
      assert_predicate status, :success?, err
      assert_equal %w[creative_retrieval_service creative_update_service], calls.map { |c| c["name"] }
      assert_equal({ "id" => 77, "level" => 1, "format" => "json" }, calls.first["arguments"])
      assert_equal 77, calls.last.dig("arguments", "id")
      assert_includes calls.last.dig("arguments", "description"), "```ruby\nmodule Tools\n"
      assert_includes err, "pending approval"
    end
  end

  test "update refuses renaming onto another Creative's registered tool" do
    responses = { "creative_retrieval_service" => owner(77, "old_probe"), "meta_tool" => '{"name":"authored_probe"}' }
    with_fake_mcp(responses) do |home, calls|
      _out, err, status = cli_with_source(home, "update", "77")
      assert_not_predicate status, :success?
      assert_includes err, 'Tool "authored_probe" already exists'
      assert_equal %w[creative_retrieval_service meta_tool], calls.map { |c| c["name"] }
    end
  end

  test "update to a free name checks the registry, then saves" do
    plain = [ { id: 77, description: "Notes only" } ].to_json
    with_fake_mcp("creative_retrieval_service" => plain, "meta_tool" => NOT_FOUND) do |home, calls|
      _out, err, status = cli_with_source(home, "update", "77")
      assert_predicate status, :success?, err
      assert_equal %w[creative_retrieval_service meta_tool creative_update_service], calls.map { |c| c["name"] }
    end
  end

  test "update fails for a missing Creative or a rejected save" do
    with_fake_mcp("creative_retrieval_service" => "[]") do |home, calls|
      _out, err, status = cli_with_source(home, "update", "77")
      assert_not_predicate status, :success?
      assert_includes err, "Creative 77 not found"
      assert_equal %w[creative_retrieval_service], calls.map { |c| c["name"] }
    end

    responses = {
      "creative_retrieval_service" => owner(77, "authored_probe"),
      "creative_update_service" => [ "No write permission on this Creative", true ]
    }
    with_fake_mcp(responses) do |home, _calls|
      _out, err, status = cli_with_source(home, "update", "77")
      assert_not_predicate status, :success?
      assert_includes err, "Error: request failed"
      assert_not_includes err, "pending approval"
    end
  end

  test "update ignores tool names that only appear in the Creative's text" do
    decoy = "Tool module Tools extend ToolMeta tool_name \"old_probe\" # tool_name \"authored_probe\" end"
    responses = {
      "creative_retrieval_service" => [ { id: 77, description: decoy, mcp_tools: [ "old_probe" ] } ].to_json,
      "meta_tool" => '{"name":"authored_probe"}'
    }
    with_fake_mcp(responses) do |home, calls|
      _out, err, status = cli_with_source(home, "update", "77")
      assert_not_predicate status, :success?
      assert_includes err, 'Tool "authored_probe" already exists'
      assert_equal %w[creative_retrieval_service meta_tool], calls.map { |c| c["name"] }
    end
  end

  test "update reads the real retrieval output of a scaffolded tool Creative" do
    user = users(:one)
    host = Creative.new(user: user)
    host.content_type_input = "markdown"
    host.markdown_source = dry_run(scaffold(desc: 'Probe "q" #{x} \\ e'), "--parent", "1")
    host.save!
    Collavre::McpService.new.update_from_creative(host)
    retrieved = Current.set(user: user) do
      Tools::CreativeRetrievalService.new.call(id: host.id, level: 1, format: "json")
    end
    assert_includes retrieved.first[:description], "{ error: "

    with_fake_mcp("creative_retrieval_service" => retrieved.to_s) do |home, calls|
      _out, err, status = cli_with_source(home, "update", host.id.to_s)
      assert_predicate status, :success?, err
      assert_equal %w[creative_retrieval_service creative_update_service], calls.map { |c| c["name"] }
    end
  end

  test "rejects sources the server would not register as intended" do
    spaced = scaffold.sub("extend ToolMeta", "extend  ToolMeta")
    assert_includes invalid(spaced), "Missing `extend ToolMeta` (exactly one space)"

    shadowed = scaffold.sub("    tool_name", "    # tool_name \"other_probe\"\n    tool_name")
    assert_includes invalid(shadowed), 'tool_name is read as "other_probe" by the server, not "authored_probe"'

    redeclared = scaffold.sub("    tool_description", "    tool_name \"other_probe\"\n    tool_description")
    assert_includes invalid(redeclared), "tool_name appears 2 times; declare it exactly once"

    mismatched = scaffold.sub('tool_name "authored_probe"', %q(tool_name "authored_probe'))
    assert_includes invalid(mismatched), 'tool_name "authored_probe" must be a single string literal with matching quotes'
  end

  test "approval refuses a source whose class declares a different tool_name" do
    user = users(:one)
    source = scaffold.sub("    tool_description", "    tool_name \"shadow_probe\"\n    tool_description")
    host = Creative.new(user: user)
    host.content_type_input = "markdown"
    host.markdown_source = "# probe\n\n```ruby\n#{source}```\n"
    host.save!
    Collavre::McpService.new.update_from_creative(host)

    tool = McpTool.find_by!(name: "authored_probe")
    error = assert_raises(RuntimeError) { tool.approve! }
    assert_match(/declares tool_name "shadow_probe", expected "authored_probe"/, error.message)
    assert_not tool.reload.active?
    assert_not_includes ToolMeta.registry, Tools::AuthoredProbeService
    assert_nil Tools::MetaToolService.new.find_schema("shadow_probe")
  end

  test "a source that fails after extending ToolMeta leaves nothing registered" do
    raising = scaffold.sub("    tool_description", "    raise \"boom\"\n    tool_description")
    helper = scaffold + <<~RUBY
      class Tools::AuthoredProbeHelper
        extend ToolMeta
      end
    RUBY

    { raising => /Failed to evaluate source: boom/, raising.sub('raise "boom"', "raise NotImplementedError, \"later\"") => /Failed to evaluate source: later/ }
      .each do |source, message|
        tool = approvable_tool(source)
        assert_no_changes -> { ToolMeta.registry.dup } do
          assert_raises(RuntimeError, match: message) { tool.approve! }
        end
        assert_not tool.reload.active?
        assert_nil Tools::MetaToolService.new.find_schema("authored_probe")
        tool.creative.destroy!
      end

    approvable_tool(helper).approve!
    assert_includes ToolMeta.registry, Tools::AuthoredProbeService
    assert_not_includes ToolMeta.registry, Tools::AuthoredProbeHelper
  ensure
    Tools.send(:remove_const, :AuthoredProbeHelper) if Tools.const_defined?(:AuthoredProbeHelper, false)
  end

  test "a registration during another's evaluation survives that evaluation's rollback" do
    waiting = scaffold.sub("    tool_description", "    CollavreToolAuthoringTest::EVAL_STARTED << true\n    CollavreToolAuthoringTest::EVAL_GATE.pop\n    raise \"late\"\n    tool_description")
    other = scaffold.gsub("authored_probe", "authored_probe_b").gsub("AuthoredProbeService", "AuthoredProbeBService")

    failing = Thread.new { Collavre::McpService.register_tool_from_source(waiting, expected_name: "authored_probe") rescue $! }
    EVAL_STARTED.pop
    concurrent = Thread.new { Collavre::McpService.register_tool_from_source(other, expected_name: "authored_probe_b") }
    assert_nil concurrent.join(0.5), "registration must wait for the in-flight evaluation"
    EVAL_GATE << true

    assert_match(/Failed to evaluate source: late/, failing.value.message)
    concurrent.join
    assert_includes ToolMeta.registry, Tools::AuthoredProbeBService
    assert Tools::MetaToolService.new.find_schema("authored_probe_b")
  ensure
    EVAL_GATE << true if failing&.alive?
    [ failing, concurrent ].compact.each { |t| t.join(5) }
    EVAL_STARTED.clear
    EVAL_GATE.clear
    Tools::MetaToolWriteService.new.delete_tool("authored_probe_b")
    Tools.send(:remove_const, :AuthoredProbeBService) if Tools.const_defined?(:AuthoredProbeBService, false)
  end

  test "approval refuses a class another tool or the application already defines" do
    owner = approvable_tool(scaffold)
    owner.approve!
    other = approvable_tool(scaffold.sub('tool_name "authored_probe"', 'tool_name "other_probe"'), "other_probe")
    builtin = approvable_tool(scaffold.sub("AuthoredProbeService", "CreativeRetrievalService").sub('tool_name "authored_probe"', 'tool_name "builtin_probe"'), "builtin_probe")
    builtin_metadata = Tools::CreativeRetrievalService.tool_metadata.dup

    { other => "Tools::AuthoredProbeService", builtin => "Tools::CreativeRetrievalService" }.each do |tool, class_name|
      assert_raises(RuntimeError, match: /#{class_name} is already defined by another tool or the application/) { tool.approve! }
      assert_not tool.reload.active?
    end
    assert_equal builtin_metadata, Tools::CreativeRetrievalService.tool_metadata
    assert_equal "authored_probe", Tools::AuthoredProbeService.tool_metadata[:name]
    assert_nil Tools::MetaToolService.new.find_schema("other_probe")

    Tools::MetaToolWriteService.new.delete_tool("authored_probe")
    owner.approve!
    assert Tools::MetaToolService.new.find_schema("authored_probe"), "a tool may reopen the class it defined"
  end

  test "re-approval requires the source to redeclare the class it registers" do
    approved = approvable_tool(scaffold)
    approved.approve!
    stale = "class Tools::AuthoredProbeService\nend\n\n" + scaffold.sub("AuthoredProbeService", "AuthoredProbeNextService")
    host = approved.creative
    host.content_type_input = "markdown"
    host.markdown_source = "# probe\n\n```ruby\n#{stale}```\n"
    host.save!
    Collavre::McpService.new.update_from_creative(host)
    tool = McpTool.find_by!(name: "authored_probe")
    assert_not tool.active?, "editing the source resets approval"

    assert_raises(RuntimeError, match: /Tools::AuthoredProbeService does not extend ToolMeta in the source/) { tool.approve! }
    assert_not tool.reload.active?
    assert_not_includes ToolMeta.registry, Tools::AuthoredProbeService
    assert_not_includes ToolMeta.registry, Tools::AuthoredProbeNextService
    assert_nil Tools::MetaToolService.new.find_schema("authored_probe")
  ensure
    Tools.send(:remove_const, :AuthoredProbeNextService) if Tools.const_defined?(:AuthoredProbeNextService, false)
  end

  test "a verified class leaves the registry when building its tool classes fails" do
    unsigned = approvable_tool(scaffold.sub(/^    sig \{.*\n/, ""))
    assert_raises(RuntimeError, match: /Failed to register tool/) { unsigned.approve! }
    assert_not unsigned.reload.active?
    assert_not_includes ToolMeta.registry, Tools::AuthoredProbeService

    tool = unsigned
    tool.update!(source_code: scaffold)
    ToolSchema::FastMcpFactory.stub(:build, ->(*) { raise ArgumentError, "bad schema" }) do
      assert_raises(RuntimeError, match: /Failed to register Tools::AuthoredProbeService: bad schema/) { tool.approve! }
    end
    assert_not tool.reload.active?
    assert_not_includes ToolMeta.registry, Tools::AuthoredProbeService
    assert_not Tools.const_defined?(:AuthoredProbe, false), "the RubyLLM tool built before the failure is removed"
    assert_nil Tools::MetaToolService.new.find_schema("authored_probe")
  end

  test "a tool can re-approve its class after the service is reloaded" do
    tool = approvable_tool(scaffold)
    tool.approve!
    Tools::MetaToolWriteService.new.delete_tool("authored_probe")
    reload_mcp_service

    tool.approve!
    assert Tools::MetaToolService.new.find_schema("authored_probe")
  end

  private

  # What a development reload does: a fresh McpService (and its ::McpService
  # alias), while the dynamically evaluated tool classes stay defined.
  def reload_mcp_service
    path = Collavre::McpService.method(:register_tool_from_source).source_location.first
    Collavre.send(:remove_const, :McpService)
    load path
    Object.send(:remove_const, :McpService)
    Object.const_set(:McpService, Collavre::McpService)
  end

  def approvable_tool(source, name = "authored_probe")
    host = Creative.new(user: users(:one))
    host.content_type_input = "markdown"
    host.markdown_source = "# probe\n\n```ruby\n#{source}```\n"
    host.save!
    Collavre::McpService.new.update_from_creative(host)
    McpTool.find_by!(name: name)
  end

  def owner(id, tool_name)
    [ { id: id, description: "Tool module Tools extend ToolMeta tool_name \"#{tool_name}\" end", mcp_tools: [ tool_name ] } ].to_json
  end

  def invalid(source)
    Dir.mktmpdir do |dir|
      file = File.join(dir, "tool.rb")
      File.write(file, source)
      _out, err, status = cli("tool", "create", "--parent", "1", "--file", file, home: dir)
      assert_not_predicate status, :success?
      err
    end
  end

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
  # POSTed tools/call is answered on the SSE stream. `responses` maps a tool name
  # to its text, or to [text, isError].
  def with_fake_mcp(responses)
    server = TCPServer.new("127.0.0.1", 0)
    calls = []
    sse = Queue.new
    thread = Thread.new do
      loop do
        socket = server.accept
        Thread.new(socket) { |s| serve_fake_mcp(s, sse, calls, responses) }
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

  def serve_fake_mcp(socket, sse, calls, responses)
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
      text, is_error = responses.fetch(params["name"], '{"ok":true}')
      result = { content: [ { type: "text", text: text } ], isError: is_error == true }
      stream = sse.pop
      sse << stream
      stream.write("data: #{{ jsonrpc: '2.0', id: body['id'], result: result }.to_json}\n\n")
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
