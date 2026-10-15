# frozen_string_literal: true

require "json"
require "socket"

module Perf
  # A local OpenAI-compatible endpoint that stands in for a real provider during
  # load tests. Agents point their gateway_url at it, so a load run exercises the
  # whole production path (web -> Solid Queue -> orchestrator -> RubyLLM ->
  # HTTP stream) while the "model" costs nothing and answers on a fixed clock.
  #
  # Every request is held open for `stream_seconds`, the way a real turn holds
  # its worker thread and DB connection. The server records when each request
  # arrived and finished and how many were in flight at once — peak in-flight is
  # the number that tells whether N users x M agents really ran in parallel.
  #
  # A request is attributed to a load-test message by the last `tag_pattern`
  # match in its body (the newest message in the prompt). Only tagged requests
  # count toward in-flight and its peak, so a stray turn left queued by an
  # earlier run cannot stand in for a missing one of this run.
  class FakeLlmServer
    Request = Struct.new(:tag, :path, :started_at, :finished_at, keyword_init: true)

    attr_reader :port

    def initialize(stream_seconds:, chunks: 10, tag_pattern: /PERF-[\w-]+/, host: "127.0.0.1", port: 0,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @stream_seconds = stream_seconds.to_f
      @chunks = [ chunks.to_i, 1 ].max
      @tag_pattern = tag_pattern
      @clock = clock
      @server = TCPServer.new(host, port)
      @port = @server.addr[1]
      @host = host
      @mutex = Mutex.new
      @requests = []
      @in_flight = 0
      @peak_in_flight = 0
    end

    def base_url
      "http://#{@host}:#{port}/v1"
    end

    def start
      @acceptor = Thread.new do
        loop do
          socket = @server.accept
          Thread.new(socket) { |s| handle(s) }
        end
      rescue IOError, Errno::EBADF
        nil
      end
      self
    end

    def stop
      @server.close unless @server.closed?
      @acceptor&.join(1)
    end

    def requests
      @mutex.synchronize { @requests.map(&:dup) }
    end

    def peak_in_flight
      @mutex.synchronize { @peak_in_flight }
    end

    def in_flight
      @mutex.synchronize { @in_flight }
    end

    private

    def handle(socket)
      method, path, body = read_request(socket)
      return unless method

      if method == "GET" && path.end_with?("/models")
        write_json(socket, { object: "list", data: [ { id: "perf-fake", object: "model" } ] })
      elsif method == "POST" && path.end_with?("/chat/completions")
        complete(socket, path, body)
      else
        socket.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      end
    rescue IOError, SystemCallError
      nil
    ensure
      socket.close unless socket.closed?
    end

    def read_request(socket)
      request_line = socket.gets
      return unless request_line

      method, path = request_line.split(" ", 3)
      headers = {}
      while (line = socket.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.strip.downcase] = value.to_s.strip
      end
      length = headers["content-length"].to_i
      [ method, path, length.positive? ? socket.read(length) : "" ]
    end

    def complete(socket, path, body)
      payload = JSON.parse(body) rescue {}
      request = track_start(path, body.scan(@tag_pattern).last)
      begin
        payload["stream"] ? stream(socket, request) : respond(socket, request)
      ensure
        track_finish(request)
      end
    end

    def stream(socket, request)
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" \
                   "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
      @chunks.times do |index|
        sleep(@stream_seconds / @chunks)
        write_event(socket, chunk_body(delta: { role: "assistant", content: piece(request, index) }))
      end
      write_event(socket, chunk_body(delta: {}, finish_reason: "stop",
                                     usage: { prompt_tokens: 10, completion_tokens: @chunks, total_tokens: 10 + @chunks }))
      write_chunk(socket, "data: [DONE]\n\n")
      write_chunk(socket, "")
    end

    def respond(socket, request)
      sleep(@stream_seconds)
      text = Array.new(@chunks) { |index| piece(request, index) }.join
      write_json(socket, {
        id: "perf", object: "chat.completion", created: Time.now.to_i, model: "perf-fake",
        choices: [ { index: 0, message: { role: "assistant", content: text }, finish_reason: "stop" } ],
        usage: { prompt_tokens: 10, completion_tokens: @chunks, total_tokens: 10 + @chunks }
      })
    end

    def piece(request, index)
      index.zero? ? "ack #{request.tag} " : "."
    end

    def chunk_body(delta:, finish_reason: nil, usage: nil)
      body = { id: "perf", object: "chat.completion.chunk", created: Time.now.to_i, model: "perf-fake",
               choices: [ { index: 0, delta: delta, finish_reason: finish_reason } ] }
      body[:usage] = usage if usage
      body
    end

    def write_event(socket, body)
      write_chunk(socket, "data: #{JSON.generate(body)}\n\n")
    end

    def write_chunk(socket, data)
      socket.write("#{data.bytesize.to_s(16)}\r\n#{data}\r\n")
    end

    def write_json(socket, body)
      json = JSON.generate(body)
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}")
    end

    def track_start(path, tag)
      @mutex.synchronize do
        if tag
          @in_flight += 1
          @peak_in_flight = [ @peak_in_flight, @in_flight ].max
        end
        Request.new(tag: tag, path: path, started_at: @clock.call).tap { |request| @requests << request }
      end
    end

    def track_finish(request)
      @mutex.synchronize do
        @in_flight -= 1 if request.tag
        request.finished_at = @clock.call
      end
    end
  end
end
