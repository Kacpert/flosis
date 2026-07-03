require "test_helper"

class EstimateParserTest < ActiveSupport::TestCase
  def block(json)
    "Here's my estimate:\n<estimate>\n#{json}\n</estimate>"
  end

  test "extracts a valid estimate with Fibonacci points and rationale" do
    json = { points: 8, rationale: "Touches export + aggregation service, moderate scope." }.to_json

    result = EstimateParser.extract(block(json))

    assert_equal 8, result[:points]
    assert_equal "Touches export + aggregation service, moderate scope.", result[:rationale]
  end

  test "accepts every Fibonacci value" do
    BreakdownParser::FIBONACCI.each do |pts|
      json = { points: pts, rationale: "r" }.to_json
      result = EstimateParser.extract(block(json))
      assert_equal pts, result[:points], "expected #{pts} to be accepted"
    end
  end

  test "returns nil when points is not a Fibonacci value" do
    json = { points: 4, rationale: "r" }.to_json
    assert_nil EstimateParser.extract(block(json))
  end

  test "returns nil when there is no estimate block" do
    assert_nil EstimateParser.extract("Just some prose with no block at all.")
  end

  test "returns nil on garbage JSON inside the block" do
    assert_nil EstimateParser.extract("<estimate>not json at all</estimate>")
  end

  test "returns nil on blank input" do
    assert_nil EstimateParser.extract("")
    assert_nil EstimateParser.extract(nil)
  end

  test "returns nil when points is missing" do
    json = { rationale: "r" }.to_json
    assert_nil EstimateParser.extract(block(json))
  end

  test "uses the last estimate block when multiple are present" do
    first = { points: 3, rationale: "first" }.to_json
    second = { points: 13, rationale: "second, revised" }.to_json
    text = "<estimate>#{first}</estimate>\nMore thinking...\n<estimate>#{second}</estimate>"

    result = EstimateParser.extract(text)
    assert_equal 13, result[:points]
    assert_equal "second, revised", result[:rationale]
  end

  test "rationale defaults to empty string when absent" do
    json = { points: 5 }.to_json
    result = EstimateParser.extract(block(json))
    assert_equal 5, result[:points]
    assert_equal "", result[:rationale]
  end
end
