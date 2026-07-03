require "test_helper"

class AttributionParserTest < ActiveSupport::TestCase
  def block(json)
    "Here's my forensic analysis:\n<attribution>\n#{json}\n</attribution>"
  end

  def valid_attrs(overrides = {})
    {
      origin_kind: "new_functionality",
      author_name: "Kacper",
      author_email: "k@x.com",
      confidence: "high",
      reasoning: "Introduced in commit abc123 which added the export feature."
    }.merge(overrides)
  end

  test "extracts a valid attribution with all fields" do
    json = valid_attrs.to_json
    result = AttributionParser.extract(block(json))

    assert_equal "new_functionality", result[:origin_kind]
    assert_equal "Kacper", result[:author_name]
    assert_equal "k@x.com", result[:author_email]
    assert_equal "high", result[:confidence]
    assert_equal "Introduced in commit abc123 which added the export feature.", result[:reasoning]
  end

  test "accepts existing_code origin_kind" do
    json = valid_attrs(origin_kind: "existing_code").to_json
    result = AttributionParser.extract(block(json))

    assert_equal "existing_code", result[:origin_kind]
  end

  test "accepts every valid confidence level" do
    %w[high medium low].each do |level|
      json = valid_attrs(confidence: level).to_json
      result = AttributionParser.extract(block(json))
      assert_equal level, result[:confidence], "expected #{level} to be accepted"
    end
  end

  test "returns nil when there is no attribution block" do
    assert_nil AttributionParser.extract("Just some prose, no block here at all.")
  end

  test "returns nil on garbage JSON inside the block" do
    assert_nil AttributionParser.extract("<attribution>not valid json</attribution>")
  end

  test "returns nil when the parsed JSON is not a hash" do
    assert_nil AttributionParser.extract("<attribution>[1,2,3]</attribution>")
  end

  test "returns nil on blank input" do
    assert_nil AttributionParser.extract("")
    assert_nil AttributionParser.extract(nil)
  end

  test "returns nil when origin_kind is invalid" do
    json = valid_attrs(origin_kind: "bogus_kind").to_json
    assert_nil AttributionParser.extract(block(json))
  end

  test "returns nil when confidence is invalid" do
    json = valid_attrs(confidence: "super-sure").to_json
    assert_nil AttributionParser.extract(block(json))
  end

  test "returns the LAST valid attribution block when multiple are present" do
    first = valid_attrs(author_name: "First Guess", confidence: "low").to_json
    second = valid_attrs(author_name: "Revised Guess", confidence: "high").to_json
    text = "<attribution>#{first}</attribution>\nMore digging...\n<attribution>#{second}</attribution>"

    result = AttributionParser.extract(text)
    assert_equal "Revised Guess", result[:author_name]
    assert_equal "high", result[:confidence]
  end

  test "reasoning and author fields default to empty string when absent" do
    json = { origin_kind: "existing_code", confidence: "medium" }.to_json
    result = AttributionParser.extract(block(json))

    assert_equal "existing_code", result[:origin_kind]
    assert_equal "medium", result[:confidence]
    assert_equal "", result[:author_name]
    assert_equal "", result[:author_email]
    assert_equal "", result[:reasoning]
  end

  test "returns nil when origin_kind is missing" do
    json = { confidence: "high", author_name: "X" }.to_json
    assert_nil AttributionParser.extract(block(json))
  end

  test "returns nil when confidence is missing" do
    json = { origin_kind: "existing_code", author_name: "X" }.to_json
    assert_nil AttributionParser.extract(block(json))
  end
end
