require "test_helper"

class BreakdownParserTest < ActiveSupport::TestCase
  def block(json)
    "Here's the breakdown:\n<breakdown>\n#{json}\n</breakdown>"
  end

  test "parses a valid broken-down result" do
    json = {
      needs_breakdown: true,
      total_points: 13,
      strategy: "Split by role",
      warning: nil,
      subtasks: [
        { title: "Manager flow", points: 8, description: "do X", order: 1, depends_on: [] },
        { title: "Employee flow", points: 5, description: "do Y", order: 2, depends_on: ["Manager flow"] }
      ]
    }.to_json

    result = BreakdownParser.extract_latest(block(json))
    assert result.present?
    assert_equal 13, result["total_points"]
    assert_equal true, result["needs_breakdown"]
    assert_equal 2, result["subtasks"].length
    assert_equal "Manager flow", result["subtasks"].first["title"]
    assert_equal ["Manager flow"], result["subtasks"].last["depends_on"]
  end

  test "accepts a small task with needs_breakdown false and no subtasks" do
    json = { needs_breakdown: false, total_points: 3, strategy: "Small", subtasks: [] }.to_json
    result = BreakdownParser.extract_latest(block(json))
    assert result.present?
    assert_equal false, result["needs_breakdown"]
    assert_empty result["subtasks"]
  end

  test "rejects non-Fibonacci subtask points" do
    json = {
      needs_breakdown: true, total_points: 8, strategy: "x",
      subtasks: [{ title: "A", points: 4, description: "y", order: 1, depends_on: [] }]
    }.to_json
    assert_nil BreakdownParser.extract_latest(block(json))
  end

  test "rejects non-Fibonacci total_points" do
    json = { needs_breakdown: false, total_points: 7, strategy: "x", subtasks: [] }.to_json
    assert_nil BreakdownParser.extract_latest(block(json))
  end

  test "rejects needs_breakdown true with empty subtasks" do
    json = { needs_breakdown: true, total_points: 8, strategy: "x", subtasks: [] }.to_json
    assert_nil BreakdownParser.extract_latest(block(json))
  end

  test "rejects subtask without a title" do
    json = {
      needs_breakdown: true, total_points: 8, strategy: "x",
      subtasks: [{ title: "", points: 8, description: "y", order: 1, depends_on: [] }]
    }.to_json
    assert_nil BreakdownParser.extract_latest(block(json))
  end

  test "rejects malformed JSON" do
    assert_nil BreakdownParser.extract_latest("<breakdown>\n{not json}\n</breakdown>")
  end

  test "returns empty array when no breakdown block present" do
    assert_empty BreakdownParser.extract_all("just a normal chat reply")
  end

  test "coerces string points to integers" do
    json = '{"needs_breakdown": false, "total_points": "5", "strategy": "x", "subtasks": []}'
    result = BreakdownParser.extract_latest(block(json))
    assert_equal 5, result["total_points"]
  end

  test "extract_all returns every valid block, extract_latest returns the last" do
    first = { needs_breakdown: false, total_points: 3, strategy: "v1", subtasks: [] }.to_json
    second = { needs_breakdown: false, total_points: 5, strategy: "v2", subtasks: [] }.to_json
    text = "#{block(first)}\nrevised:\n#{block(second)}"
    all = BreakdownParser.extract_all(text)
    assert_equal 2, all.length
    assert_equal "v2", BreakdownParser.extract_latest(text)["strategy"]
  end
end
