# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "socket"

class CollavreCliTest < ActiveSupport::TestCase
  test "auth creates and repairs credential paths with owner-only modes" do
    [ false, true ].each do |preexisting|
      Dir.mktmpdir do |home|
        config_dir = File.join(home, ".config", "collavre")
        config_file = File.join(config_dir, "config.json")
        exposed_file = nil
        original_inode = nil
        if preexisting
          FileUtils.mkdir_p(config_dir)
          File.write(config_file, "{}")
          File.chmod(0o755, config_dir)
          File.chmod(0o644, config_file)
          original_inode = File.stat(config_file).ino
          exposed_file = File.open(config_file)
        end

        stdout, stderr, status = run_auth(home)

        assert_predicate status, :success?, stderr
        assert_includes stdout, "Saved config"
        assert_equal 0o700, File.stat(config_dir).mode & 0o777
        assert_equal 0o600, File.stat(config_file).mode & 0o777
        assert_equal({ "url" => "https://collavre.example", "token" => "callback-token" },
          JSON.parse(File.read(config_file)))
        assert_empty Dir.glob(File.join(config_dir, ".config.json.*.tmp"))
        if exposed_file
          assert_not_equal original_inode, File.stat(config_file).ino
          exposed_file.rewind
          assert_equal "{}", exposed_file.read
        end
      ensure
        exposed_file&.close
      end
    end
  end

  test "attach sends COLLAVRE_TASK_ID as the X-Collavre-Task header" do
    [ [ "77", "77" ], [ nil, nil ] ].each do |task_id, expected|
      headers = capture_attach_headers(task_id)

      if expected
        assert_equal expected, headers["x-collavre-task"]
      else
        assert_not headers.key?("x-collavre-task")
      end
      assert_equal "Bearer callback-token", headers["authorization"]
    end
  end

  private

  def capture_attach_headers(task_id)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    headers = {}
    reader = Thread.new do
      client = server.accept
      while (line = client.gets) && line != "\r\n"
        name, value = line.split(":", 2)
        headers[name.downcase] = value.strip if value
      end
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
      client.close
    end

    Dir.mktmpdir do |home|
      config_dir = File.join(home, ".config", "collavre")
      FileUtils.mkdir_p(config_dir)
      File.write(File.join(config_dir, "config.json"), { url: "http://127.0.0.1:#{port}/mcp", token: "callback-token" }.to_json)
      file = File.join(home, "note.txt")
      File.write(file, "hello")
      env = { "HOME" => home, "COLLAVRE_TASK_ID" => task_id }
      script = Rails.root.join("engines/collavre/skills/collavre/scripts/collavre")
      _stdout, stderr, status = Open3.capture3(env, "node", script.to_s, "attach", "--creative", "5", "--file", file)
      assert_predicate status, :success?, stderr
    end
    reader.join(5)
    headers
  ensure
    server&.close
  end

  def run_auth(home)
    script = Rails.root.join("engines/collavre/skills/collavre/scripts/collavre")
    Open3.capture3(
      { "HOME" => home },
      "sh", "-c", 'umask 022; exec "$@"', "sh",
      "node", script.to_s, "auth",
      "--url", "https://collavre.example",
      "--token", "callback-token"
    )
  end
end
