require "test_helper"

class AlertParserTest < ActiveSupport::TestCase
  test "extracts a fired alert with summary and detail" do
    text = %(<alert>#{ { fired: true, summary: "2 tasks flagged", detail: "SP-1099, SP-1102 in QA > 3 days" }.to_json }</alert>)
    result = AlertParser.extract(text)

    assert_equal true, result[:fired]
    assert_equal "2 tasks flagged", result[:summary]
    assert_equal "SP-1099, SP-1102 in QA > 3 days", result[:detail]
  end

  test "extracts a not-fired alert" do
    text = %(<alert>#{ { fired: false, summary: "No condition met", detail: "" }.to_json }</alert>)
    result = AlertParser.extract(text)

    assert_equal false, result[:fired]
    assert_equal "No condition met", result[:summary]
  end

  test "returns nil for garbage text with no alert block" do
    assert_nil AlertParser.extract("Just some prose, no alert block here.")
  end

  test "returns nil for malformed JSON inside the block" do
    assert_nil AlertParser.extract("<alert>{not valid json</alert>")
  end

  test "returns nil when the parsed JSON is not a hash" do
    assert_nil AlertParser.extract("<alert>[1,2,3]</alert>")
  end

  test "returns nil when fired key is missing entirely" do
    assert_nil AlertParser.extract(%(<alert>#{ { summary: "x", detail: "y" }.to_json }</alert>))
  end

  test "truncates a too-long summary to 90 chars instead of rejecting it" do
    long_summary = "a" * 200
    text = %(<alert>#{ { fired: true, summary: long_summary, detail: "d" }.to_json }</alert>)
    result = AlertParser.extract(text)

    assert result[:summary].length <= 90
  end

  test "returns the LAST valid alert block when multiple are present" do
    text = <<~TEXT
      <alert>#{ { fired: false, summary: "first", detail: "" }.to_json }</alert>
      Some more reasoning...
      <alert>#{ { fired: true, summary: "final", detail: "d" }.to_json }</alert>
    TEXT
    result = AlertParser.extract(text)

    assert_equal true, result[:fired]
    assert_equal "final", result[:summary]
  end

  test "blank text returns nil" do
    assert_nil AlertParser.extract("")
    assert_nil AlertParser.extract(nil)
  end
end
