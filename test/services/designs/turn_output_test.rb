require "test_helper"

class Designs::TurnOutputTest < ActiveSupport::TestCase
  test "reads the summary, new contexts and missing requirements" do
    result = Designs::TurnOutput.parse(<<~TEXT)
      Done.
      <summary>Added the Archived tab and its empty state.</summary>
      <context>Plan: Free — archive hidden</context>
      <missing>What does a candidate see on an archived offer?</missing>
      <missing>Can an archived offer be restored?</missing>
    TEXT
    assert_equal "Added the Archived tab and its empty state.", result.summary
    assert_equal [ "Plan: Free — archive hidden" ], result.contexts
    assert_equal 2, result.missing.size
  end

  test "a reply without a summary block still yields a summary" do
    assert_equal "Just text", Designs::TurnOutput.parse("  Just text  ").summary
  end

  test "a reply without a summary block is cut to its first 300 characters" do
    assert_equal "a" * 300, Designs::TurnOutput.parse("  #{"a" * 500}  ").summary
  end

  test "a summary keeps its lines, and the other blocks are trimmed, may span lines and are dropped when empty" do
    result = Designs::TurnOutput.parse(<<~TEXT)
      <summary>
      Added the Archived tab.
      Archived offers are listed newest first.
      </summary>
      <context>
        Plan: Pro — archive shown
      </context>
      <context>   </context>
      <missing>Who may archive
      an offer?</missing>
      <missing></missing>
    TEXT
    assert_equal "Added the Archived tab.\nArchived offers are listed newest first.", result.summary
    assert_equal [ "Plan: Pro — archive shown" ], result.contexts
    assert_equal [ "Who may archive\nan offer?" ], result.missing
  end

  test "a reply with nothing in it yields an empty result" do
    [ nil, "", " \n " ].each do |reply|
      result = Designs::TurnOutput.parse(reply)
      assert_equal "", result.summary
      assert_equal [], result.contexts
      assert_equal [], result.missing
    end
  end
end
