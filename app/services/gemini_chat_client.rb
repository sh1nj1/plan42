require "net/http"
require "json"

class GeminiChatClient
  STREAM_URL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:streamGenerateContent"

  def initialize(api_key: ENV["GEMINI_API_KEY"])
    @api_key = api_key
  end

  def chat(contents)
    return if @api_key.blank?
    uri = URI("#{STREAM_URL}?key=#{@api_key}")
    request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
    request.body = { contents: contents }.to_json
    Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request) do |response|
        response.read_body do |chunk|
          chunk.strip!
          next if chunk.blank?
          json = JSON.parse(chunk)
          text = json.dig("candidates", 0, "content", "parts", 0, "text")
          yield text if block_given? && text
        end
      end
    end
  rescue StandardError => e
    Rails.logger.error("Gemini chat error: #{e.message}")
  end
end
