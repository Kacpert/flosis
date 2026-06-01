require "test_helper"

class BreakdownParserTest < ActiveSupport::TestCase
  def block(json)
    "Here's the breakdown:\n<breakdown>\n#{json}\n</breakdown>"
  end

  # A valid sub-task with all required fields; override any of them per test.
  def subtask(overrides = {})
    {
      title: "Manager flow", points: 8, description: "do X",
      acceptance_criteria: ["Manager can do the thing", "Unauthorized manager cannot"],
      figma_links: [], order: 1, depends_on: []
    }.merge(overrides)
  end

  test "parses a valid broken-down result" do
    json = {
      needs_breakdown: true,
      strategy: "Split by role",
      warning: nil,
      subtasks: [
        subtask(title: "Manager flow", points: 8, order: 1, depends_on: []),
        subtask(title: "Employee flow", points: 5, order: 2, depends_on: ["Manager flow"])
      ]
    }.to_json

    result = BreakdownParser.extract_latest(block(json))
    assert result.present?
    assert_equal 13, result["total_points"], "total is the server-computed sum of slices (8+5)"
    assert_equal true, result["needs_breakdown"]
    assert_equal 2, result["subtasks"].length
    assert_equal "Manager flow", result["subtasks"].first["title"]
    assert_equal ["Manager flow"], result["subtasks"].last["depends_on"]
    assert_equal 2, result["subtasks"].first["acceptance_criteria"].length
  end

  test "parses acceptance criteria and figma links per sub-task" do
    json = {
      needs_breakdown: true, strategy: "x",
      subtasks: [
        subtask(
          title: "Manager view", points: 8,
          acceptance_criteria: ["AC one", "AC two", "  ", "AC three"],
          figma_links: [
            { label: "Manager frame", url: "https://www.figma.com/design/abc/HR?node-id=1-2" },
            "https://www.figma.com/design/abc/HR",
            { label: "bad", url: "javascript:alert(1)" }
          ]
        )
      ]
    }.to_json

    st = BreakdownParser.extract_latest(block(json))["subtasks"].first
    assert_equal ["AC one", "AC two", "AC three"], st["acceptance_criteria"], "blank criteria dropped"
    assert_equal 2, st["figma_links"].length, "non-http(s) link (javascript:) dropped"
    assert_equal "Manager frame", st["figma_links"].first["label"]
    assert_equal "Figma", st["figma_links"].last["label"], "bare URL gets default label"
    assert st["figma_links"].none? { |l| l["url"].start_with?("javascript:") }
  end

  test "accepts a sub-task with no figma links (parent ticket has no figma)" do
    json = {
      needs_breakdown: true, strategy: "x",
      subtasks: [subtask(points: 5, figma_links: [])]
    }.to_json
    result = BreakdownParser.extract_latest(block(json))
    assert result.present?, "missing figma must NOT reject the breakdown"
    assert_empty result["subtasks"].first["figma_links"]
  end

  test "rejects a broken-down sub-task with no acceptance criteria" do
    json = {
      needs_breakdown: true, strategy: "x",
      subtasks: [subtask(acceptance_criteria: [])]
    }.to_json
    assert_nil BreakdownParser.extract_latest(block(json))
  end

  test "total_points is the sum of slices and may exceed 21" do
    json = {
      needs_breakdown: true, strategy: "Big epic",
      subtasks: [
        subtask(title: "A", points: 13, order: 1),
        subtask(title: "B", points: 8, order: 2),
        subtask(title: "C", points: 8, order: 3),
        subtask(title: "D", points: 5, order: 4),
        subtask(title: "E", points: 3, order: 5)
      ]
    }.to_json
    result = BreakdownParser.extract_latest(block(json))
    assert result.present?, "a >21 total must be accepted, not rejected"
    assert_equal 37, result["total_points"], "13+8+8+5+3 = 37, not capped to a Fibonacci value"
  end

  test "ignores AI-provided total_points and recomputes from slices" do
    json = {
      needs_breakdown: true, total_points: 999, strategy: "x",
      subtasks: [
        subtask(title: "A", points: 8, order: 1),
        subtask(title: "B", points: 5, order: 2)
      ]
    }.to_json
    result = BreakdownParser.extract_latest(block(json))
    assert_equal 13, result["total_points"], "AI's bogus 999 is ignored; server sums 8+5"
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
      needs_breakdown: true, strategy: "x",
      subtasks: [subtask(title: "A", points: 4)]
    }.to_json
    assert_nil BreakdownParser.extract_latest(block(json))
  end

  test "rejects non-Fibonacci whole-task estimate for an un-split task" do
    # When there are no slices, total_points IS the whole-task estimate and
    # must itself be Fibonacci. 7 is not.
    json = { needs_breakdown: false, total_points: 7, strategy: "x", subtasks: [] }.to_json
    assert_nil BreakdownParser.extract_latest(block(json))
  end

  test "rejects needs_breakdown true with empty subtasks" do
    json = { needs_breakdown: true, total_points: 8, strategy: "x", subtasks: [] }.to_json
    assert_nil BreakdownParser.extract_latest(block(json))
  end

  test "rejects subtask without a title" do
    json = {
      needs_breakdown: true, strategy: "x",
      subtasks: [subtask(title: "", points: 8)]
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
