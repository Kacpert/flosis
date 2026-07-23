require "test_helper"

class EstimateParserTest < ActiveSupport::TestCase
  def block(json)
    "Here's my estimate:\n<estimate>\n#{json}\n</estimate>"
  end

  test "extracts a 1-100 score, keeps it, and stores the halved value as points" do
    json = { score: 63, rationale: "Substantial: multi-file + integration." }.to_json

    result = EstimateParser.extract(block(json))

    assert_equal 63, result[:score]
    assert_equal 32, result[:points], "63/2 rounds to 32"
    assert_equal "Substantial: multi-file + integration.", result[:rationale]
  end

  test "halving is round(score/2) across the range" do
    { 1 => 1, 5 => 3, 40 => 20, 63 => 32, 84 => 42, 90 => 45, 100 => 50 }.each do |score, points|
      result = EstimateParser.extract(block({ score: score, rationale: "r" }.to_json))
      assert_equal points, result[:points], "score #{score} should store #{points}"
    end
  end

  test "accepts every score in 1..100" do
    [ 1, 7, 25, 45, 65, 85, 86, 100 ].each do |score|
      result = EstimateParser.extract(block({ score: score, rationale: "r" }.to_json))
      assert_equal score, result[:score], "expected #{score} to be accepted"
    end
  end

  test "accepts a numeric-string score (coerced to integer)" do
    assert_equal 12, EstimateParser.extract(block({ score: "12", rationale: "r" }.to_json))[:score]
  end

  test "falls back to a legacy 'points' key when 'score' is absent" do
    result = EstimateParser.extract(block({ points: 40, rationale: "r" }.to_json))
    assert_equal 40, result[:score]
    assert_equal 20, result[:points]
  end

  test "rejects out-of-range scores (0, >100, negatives) and non-numbers" do
    [ 0, -3, 101, 999, "abc" ].each do |score|
      json = { score: score, rationale: "r" }.to_json
      assert_nil EstimateParser.extract(block(json)), "expected score #{score.inspect} to be rejected"
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

  test "returns nil when the score is missing" do
    json = { rationale: "r" }.to_json
    assert_nil EstimateParser.extract(block(json))
  end

  test "uses the last estimate block when multiple are present" do
    first = { score: 30, rationale: "first" }.to_json
    second = { score: 84, rationale: "second, revised" }.to_json
    text = "<estimate>#{first}</estimate>\nMore thinking...\n<estimate>#{second}</estimate>"

    result = EstimateParser.extract(text)
    assert_equal 84, result[:score]
    assert_equal 42, result[:points]
    assert_equal "second, revised", result[:rationale]
  end

  test "rationale defaults to empty string when absent" do
    json = { score: 50 }.to_json
    result = EstimateParser.extract(block(json))
    assert_equal 50, result[:score]
    assert_equal 25, result[:points]
    assert_equal "", result[:rationale]
  end
end
