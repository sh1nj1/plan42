require "test_helper"
require "open3"

class CollavreJsonOutputTest < ActiveSupport::TestCase
  SCRIPTS = %w[
    skills/collavre/scripts/collavre
    engines/collavre/skills/collavre/scripts/collavre
  ].freeze

  test "prints string keys and nested Ruby values as JSON" do
    value = { "id" => 1, "children" => [ { "active" => true, "missing" => nil } ] }
    assert_json_output(value.inspect, value)
  end

  test "prints Ruby interpolation and escape characters as JSON" do
    value = { "description" => 'puts "#{name} #@name #$name"' + "\n\e[31m\t\\end" }
    assert_json_output(value.inspect, value)
  end

  test "preserves Ruby syntax inside strings while converting symbol keys" do
    value = { description: '{ error: nil, "id" => 1 }', missing: nil }
    assert_json_output(value.inspect, value.deep_stringify_keys)
  end

  test "preserves valid JSON with escape sequences" do
    value = { "description" => 'literal \\e and \\#{name}', "missing" => nil }
    assert_json_output(value.to_json, value)
  end

  test "preserves non JSON output" do
    SCRIPTS.each do |script|
      assert_equal "plain text\n", render_output(script, "plain text")
      assert_equal "\n", render_output(script, "")
    end
  end

  private

  def assert_json_output(input, expected)
    SCRIPTS.each do |script|
      assert_equal expected, JSON.parse(render_output(script, input)), script
    end
  end

  def render_output(script, input)
    # Exercise the actual CLI output path without opening a network connection.
    harness = <<~JS
      const fs = require('node:fs');
      const vm = require('node:vm');
      const source = fs.readFileSync(process.argv[1], 'utf8');
      const start = source.includes('function rubyStringToJson(')
        ? source.indexOf('function rubyStringToJson(')
        : source.indexOf('function fixRubyHash(');
      const end = source.indexOf('const commands =', start);
      const context = { console, decodeHtmlEntities: text => text };
      vm.createContext(context);
      vm.runInContext(source.slice(start, end), context);
      context.printResult({ content: [{ type: 'text', text: fs.readFileSync(0, 'utf8') }] });
    JS
    out, err, status = Open3.capture3("node", "-e", harness, Rails.root.join(script).to_s, stdin_data: input)
    assert_predicate status, :success?, err
    out
  end
end
