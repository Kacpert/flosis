require "test_helper"

class EstimateParserTest < ActiveSupport::TestCase
  def block(json)
    "Here's my estimate:\n<estimate>\n#{json}\n</estimate>"
  end

  test "extracts a valid estimate with an open-ended complexity number and rationale" do
    json = { points: 8, rationale: "Touches export + aggregation service, moderate scope." }.to_json

    result = EstimateParser.extract(block(json))

    assert_equal 8, result[:points]
    assert_equal "Touches export + aggregation service, moderate scope.", result[:rationale]
  end

  test "accepts any positive whole number (no Fibonacci scale, no upper limit)" do
    [ 1, 4, 7, 9, 11, 16, 18, 40, 88, 137, 500, 9999 ].each do |pts|
      json = { points: pts, rationale: "r" }.to_json
      result = EstimateParser.extract(block(json))
      assert_equal pts, result[:points], "expected #{pts} to be accepted"
    end
  end

  test "accepts a numeric string (coerced to integer)" do
    json = { points: "12", rationale: "r" }.to_json
    assert_equal 12, EstimateParser.extract(block(json))[:points]
  end

  test "rejects zero, negatives, non-numbers, and values too large to store" do
    [ 0, -3, 10_000, "abc" ].each do |pts|
      json = { points: pts, rationale: "r" }.to_json
      assert_nil EstimateParser.extract(block(json)), "expected #{pts.inspect} to be rejected"
    end
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
