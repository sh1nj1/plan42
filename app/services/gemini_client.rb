require "net/http"
require "json"

class GeminiClient
  GEMINI_URL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent"

  def initialize(api_key: ENV["GEMINI_API_KEY"])
    @api_key = api_key
  end

  def recommend_parent_ids(categories, description)
    return [] if @api_key.blank?
    lines = categories.map { |c| "#{c[:id]}, \"#{c[:path]}\"" }.join("\n")
    prompt = "#{lines}\n\nGiven the above categories (id, path), which ids are the best parents for \"#{description}\"? " \
             "Reply with up to 5 ids separated by commas in descending order of relevance."
    uri = URI("#{GEMINI_URL}?key=#{@api_key}")
    body = { contents: [ { role: "user", parts: [ { text: prompt } ] } ] }
    response = Net::HTTP.post(uri, body.to_json, "Content-Type" => "application/json")
    json = JSON.parse(response.body)
    text = json.dig("candidates", 0, "content", "parts", 0, "text")
    return [] unless text
    text.split(/[\s,]+/).map(&:to_i).reject(&:zero?).first(5)
  rescue StandardError
    []
  end
end
