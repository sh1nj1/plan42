require "test_helper"

module Collavre
  class TypoCorrectorTest < ActiveSupport::TestCase
    # Minimal stand-in for AiClient that returns a canned LLM response.
    class StubClient
      attr_reader :received

      def initialize(response)
        @response = response
      end

      def chat(contents)
        @received = contents
        @response
      end
    end

    def correct(text, response)
      TypoCorrector.new(client: StubClient.new(response)).correct(text)
    end

    test "keeps valid in-place spelling fixes" do
      text = "안녀하세요 저는 콜라브를 만들고 잇습니다"
      response = {
        edits: [
          { original: "안녀하세요", suggestion: "안녕하세요", reason: "spelling", confidence: 0.95 },
          { original: "잇습니다", suggestion: "있습니다", reason: "spelling", confidence: 0.9 }
        ]
      }.to_json

      edits = correct(text, response)

      assert_equal 2, edits.size
      assert_equal "안녕하세요", edits.first["suggestion"]
      assert_in_delta 0.95, edits.first["confidence"], 0.001
    end

    test "strips markdown code fences around the JSON" do
      text = "teh cat"
      response = "```json\n{\"edits\":[{\"original\":\"teh\",\"suggestion\":\"the\",\"confidence\":0.9}]}\n```"

      edits = correct(text, response)

      assert_equal 1, edits.size
      assert_equal "the", edits.first["suggestion"]
    end

    test "rejects edits whose original is absent from the text" do
      text = "the cat sat"
      response = { edits: [ { original: "doge", suggestion: "dog", confidence: 0.9 } ] }.to_json

      assert_empty correct(text, response)
    end

    test "rejects large rewrites that exceed the edit-distance cap" do
      text = "I beleive this"
      response = { edits: [ { original: "beleive", suggestion: "completely different", confidence: 0.9 } ] }.to_json

      assert_empty correct(text, response)
    end

    test "rejects edits that only occur inside skip regions" do
      text = "see `recieve()` and https://recieve.example.com and @recieve"
      response = { edits: [ { original: "recieve", suggestion: "receive", confidence: 0.9 } ] }.to_json

      assert_empty correct(text, response)
    end

    test "accepts an edit that occurs outside a skip region even if also inside one" do
      text = "recieve this, not `recieve()`"
      response = { edits: [ { original: "recieve", suggestion: "receive", confidence: 0.9 } ] }.to_json

      edits = correct(text, response)
      assert_equal 1, edits.size
    end

    test "defaults confidence to 0.5 when missing or non-numeric" do
      text = "teh dog"
      response = { edits: [ { original: "teh", suggestion: "the", reason: "spelling" } ] }.to_json

      edits = correct(text, response)
      assert_in_delta 0.5, edits.first["confidence"], 0.001
    end

    test "deduplicates identical edits" do
      text = "teh teh"
      response = {
        edits: [
          { original: "teh", suggestion: "the", confidence: 0.9 },
          { original: "teh", suggestion: "the", confidence: 0.8 }
        ]
      }.to_json

      assert_equal 1, correct(text, response).size
    end

    test "returns empty array for blank input without calling the LLM" do
      client = StubClient.new("should not be used")
      assert_empty TypoCorrector.new(client: client).correct("   ")
      assert_nil client.received
    end

    test "returns empty array on unparseable LLM output" do
      assert_empty correct("teh dog", "not json at all")
    end
  end
end
