require "net/http"
require "json"

class GeminiChatClient
  STREAM_URL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent"

  def initialize(api_key: ENV["GEMINI_API_KEY"])
    @api_key = api_key
  end

  def chat(contents)
    return if @api_key.blank?
    uri = URI("#{STREAM_URL}?key=#{@api_key}")
    request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
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
    request.body = { contents: contents, systemInstruction: system_instruction }.to_json
    Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request) do |response|
        response.read_body do |chunk|
          Rails.logger.info("### Gemini chunk: #{chunk}")
          begin
            chunk = chunk.to_s.strip
            next if chunk.blank?

            # Some streaming endpoints prefix lines with "data: "
            chunk = chunk.sub(/^data:\s*/, "")

            json = JSON.parse(chunk)

            # Some transports may wrap multiple payloads in an array per chunk
            if json.is_a?(Array)
              json.each do |item|
                text = extract_text_from(item)
                yield text if block_given? && text.present?
              end
              next
            end

            text = extract_text_from(json)
            yield text if block_given? && text.present?
          rescue JSON::ParserError
            # Ignore non-JSON keepalive or [DONE] style lines
            next
          rescue StandardError => inner_e
            Rails.logger.warn("Gemini chunk parse error: #{inner_e.class}: #{inner_e.message}")
            next
          end
        end
      end
    end
  rescue StandardError => e
    Rails.logger.error("Gemini chat error: #{e.message}")
    yield "Gemini API error: #{e.message}" if block_given?
  end

  private

  def extract_text_from(json)
    return nil unless json.is_a?(Hash)

    # Prefer candidates[0].content.parts[0].text
    candidates = json["candidates"]
    if candidates.is_a?(Array) && (first = candidates.first).is_a?(Hash)
      content = first["content"]
      if content.is_a?(Hash)
        parts = content["parts"]
        if parts.is_a?(Array)
          first_part = parts.first
          return first_part["text"] if first_part.is_a?(Hash) && first_part["text"].is_a?(String)
          return first_part if first_part.is_a?(String)
        end
      end
    end

    # Some responses may put text directly in top-level (fallback)
    return json["text"] if json["text"].is_a?(String)

    # If there's an error message, log it for visibility
    if json["error"].is_a?(Hash) && json["error"]["message"].is_a?(String)
      message = "Gemini API error: #{json["error"]["message"]}"
      Rails.logger.warn(message)
      return message
    end

    nil
  end
end
