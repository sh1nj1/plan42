require "net/http"
require "json"

class GeminiChatClient
  STREAM_URL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent"

  def initialize(api_key: ENV["GEMINI_API_KEY"])
    @api_key = api_key
  end

  def chat(contents)
    return if @api_key.blank?
    uri = URI(STREAM_URL)
    params = { alt: "sse", key: @api_key }
    uri.query = [uri.query, URI.encode_www_form(params)].compact.join("&") # preserve any existing query

    req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
    system_instruction = {
      parts: [
        {
          text: <<~PROMPT.strip
            You are a senior expert teammate. Respond:
            - Be concise and focus on the essentials (avoid unnecessary verbosity).
            - Use short bullet points only when helpful.
            - State only what you're confident about; briefly note any uncertainty.
            - Respond in the asker's language (prefer the latest user message). Keep code and error messages in their original form.
          PROMPT
        }
      ]
    }
    req.body = { contents: contents, systemInstruction: system_instruction }.to_json
    Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      # inside your Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      http.request(req) do |res|
        unless res.is_a?(Net::HTTPSuccess)
          # Try to surface server error payload to the room
          body = +""
          res.read_body { |c| body << c rescue nil }
          yield "[ERROR] HTTP #{res.code} #{res.message}#{body.empty? ? '' : " — #{body[0,400]}"}"
          next
        end

        # --- Rock-solid SSE parsing (CRLF-safe, partial-safe) ---
        line_buf    = +""
        event_lines = []

        # tiny helper to process one complete SSE event
        process_event = lambda do
          return if event_lines.empty?

          # Rebuild data payload from one SSE event (can include multiple data: lines)
          data = event_lines
                   .select { |l| l.start_with?("data:") }
                   .map    { |l| l.sub(/\Adata:\s?/, "") }
                   .join("\n")

          event_lines.clear
          return if data.empty? || data == "[DONE]"

          begin
            obj = JSON.parse(data)
          rescue JSON::ParserError => e
            Rails.logger.warn("SSE JSON parse error: #{e.message}")
            # Yield a short error so chat users can see it (and we keep streaming)
            yield "[ERROR] Invalid JSON chunk (continuing): #{data[0,200]}"
            return
          end

          # If API returns structured error in the stream, surface it
          if obj.is_a?(Hash) && obj["error"]
            msg = obj.dig("error", "message") || obj["error"].to_s
            yield "[ERROR] #{msg}"
            return
          end

          # Normal token emission
          parts = obj.dig("candidates", 0, "content", "parts") || []
          parts.each do |p|
            t = p["text"]
            yield t if t && !t.empty?
          end
        end

        begin
          res.read_body do |chunk|
            line_buf << chunk

            # Extract COMPLETE lines regardless of \n or \r\n
            while (newline = line_buf.index(/\r?\n/))
              # one full line without its newline
              line = line_buf.slice!(0..newline).sub(/\r?\n\z/, "")
              Rails.logger.debug { "### SSE line: #{line.inspect}" }

              if line.empty?
                # Blank line => end of event
                process_event.call
              else
                event_lines << line
              end
            end
          end
        rescue => e
          # Network/stream error: show to users
          yield "[ERROR] Stream error: #{e.class}: #{e.message}"
        ensure
          # If stream ended without a trailing blank line, flush the last event
          process_event.call if event_lines.any?
        end
      end

    end
  rescue StandardError => e
    Rails.logger.error("Gemini chat error: #{e.message}")
    yield "Gemini error: #{e.message}" if block_given?
  end

end
