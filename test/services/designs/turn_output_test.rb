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

  # Ruling P2-R16: the chat never shows a protocol tag. The prose of a reply
  # with no summary is its summary, and the blocks are left out of it, tags and
  # contents both (the context and missing blocks reach the chat on their own).
  test "a reply without a summary is its prose, with no context or missing block in it" do
    result = Designs::TurnOutput.parse(<<~TEXT)
      Added the Archived tab.
      <context>Plan: Free — archive hidden</context>
      <missing>What does a candidate see on an archived offer?</missing>
    TEXT
    assert_equal "Added the Archived tab.", result.summary
    assert_equal [ "Plan: Free — archive hidden" ], result.contexts
    assert_equal [ "What does a candidate see on an archived offer?" ], result.missing
  end

  test "prose on both sides of a block is kept and the block is gone" do
    reply = "Added the tab.\n<missing>Can an offer be restored?</missing>\nIt lists offers newest first."
    assert_equal "Added the tab.\n\nIt lists offers newest first.", Designs::TurnOutput.parse(reply).summary
  end

  test "an empty summary block is no summary, and no tag shows either" do
    assert_equal "Done.", Designs::TurnOutput.parse("Done.\n<summary>  </summary>").summary
  end

  test "a reply made of blocks only has an empty summary" do
    result = Designs::TurnOutput.parse(<<~TEXT)
      <context>Plan: Free — archive hidden</context>
      <missing>Can an offer be restored?</missing>
    TEXT
    assert_equal "", result.summary
    assert_equal [ "Plan: Free — archive hidden" ], result.contexts
    assert_equal [ "Can an offer be restored?" ], result.missing
  end

  test "the 300 characters are counted without the blocks" do
    reply = "<missing>#{"q" * 400}</missing>#{"p" * 500}"
    assert_equal "p" * 300, Designs::TurnOutput.parse(reply).summary
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

  # Designs imports: a setup turn blocked by something only the person can fix
  # ends with its question for them.
  test "a blocked block is the turn's question and stays out of the summary" do
    result = Designs::TurnOutput.parse(<<~TEXT)
      <summary>Built the board's empty state.</summary>
      <blocked>The board is empty for every context. Connect Jira on the test project and tell me to go on.</blocked>
    TEXT
    assert_equal "The board is empty for every context. Connect Jira on the test project and tell me to go on.", result.blocked
    assert_equal "Built the board's empty state.", result.summary
  end

  test "a reply that is only a question still has a summary" do
    result = Designs::TurnOutput.parse("<blocked>Connect Jira on the test project?</blocked>")
    assert_equal [ "Connect Jira on the test project?" ] * 2, [ result.summary, result.blocked ]
  end

  test "comes-in, kept and replaced blocks are read in order" do
    result = Designs::TurnOutput.parse("<summary>Updated Bug Reporting.</summary><comes-in>Filter by status.</comes-in>" \
                                       "<kept>Your redesigned bug card.</kept><replaced>Assign in the card's footer.</replaced>" \
                                       "<comes-in>The empty state.</comes-in>")
    assert_equal [ [ "Filter by status.", "The empty state." ], [ "Your redesigned bug card." ], [ "Assign in the card's footer." ] ],
                 [ result.comes_in, result.kept, result.replaced ]
    assert_equal "Updated Bug Reporting.", result.summary
  end

  test "a result made by hand needs only its summary" do
    result = Designs::TurnOutput::Result.new(summary: "Brought up to date with master.", contexts: [], missing: [])
    assert_equal [ nil, [], [], [] ], [ result.blocked, result.comes_in, result.kept, result.replaced ]
  end
end
