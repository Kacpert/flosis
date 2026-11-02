require "test_helper"

class Designs::LeakGuardTest < ActiveSupport::TestCase
  LIBRARY = "Always pair the display serif with a quiet grotesk and keep body copy at sixteen pixels."

  def change(path, text = "x") = Designs::Repo::Change.new(path: path, added_text: text)

  test "turns may change the four design folders, inspirations included" do
    paths = %w[design-system/theme.css components/button/button.html designs/admin/jobs.html inspirations/shot.png]
    assert_empty Designs::LeakGuard.new.check(paths.map { change(_1) })
  end

  test "README.md, index.html and runtime/ are Flosis's: only its own commits change them" do
    %w[README.md index.html runtime/flosis.js].each do |path|
      assert_equal [ "is outside the design repo's allowed folders" ], Designs::LeakGuard.new.check([ change(path) ]).map(&:reason), path
      assert_empty Designs::LeakGuard.new(flosis_files: true).check([ change(path) ]), path
    end
  end

  test "anything else is refused, tool configuration included" do
    %w[.claude/skills/style.md notes.md CLAUDE.md .github/workflows/x.yml designs_extra/a.html].each do |path|
      assert_equal [ "is outside the design repo's allowed folders" ],
                   Designs::LeakGuard.new.check([ change(path) ]).map(&:reason), "#{path} must be refused"
    end
  end

  test "a twelve-word passage from the library is refused however it is spaced or cased" do
    library = "Always pair the display serif with a quiet grotesk and keep body copy at sixteen pixels."
    added = "<p>ALWAYS pair the display serif with a quiet grotesk,\n and keep body copy at sixteen pixels</p>"
    violations = Designs::LeakGuard.new(forbidden_texts: [ library ]).check([ change("designs/a.html", added) ])
    assert_equal [ "contains a passage from the Flosis library" ], violations.map(&:reason)
  end

  test "eleven shared words are not a passage" do
    library = "one two three four five six seven eight nine ten eleven twelve"
    added = "one two three four five six seven eight nine ten eleven"
    assert_empty Designs::LeakGuard.new(forbidden_texts: [ library ]).check([ change("designs/a.html", added) ])
  end

  test "a stored credential is refused, and the violation does not repeat it" do
    violations = Designs::LeakGuard.new(secrets: [ "ghp_SECRET123" ]).check([ change("designs/a.html", "token=ghp_SECRET123") ])
    assert_equal [ "contains a stored credential" ], violations.map(&:reason)
    assert_not_includes violations.inspect, "ghp_SECRET123"
  end

  test "blank and short secrets are ignored" do
    assert_empty Designs::LeakGuard.new(secrets: [ nil, "", "abc" ]).check([ change("designs/a.html", "abc") ])
  end

  # Ruling R13: a nested .gitattributes can route content through a filter (LFS)
  # that the diff the guard reads never shows.
  test "git's own configuration files are refused in every folder, whatever their case" do
    %w[
      .gitignore .gitattributes .gitmodules
      designs/.gitattributes components/x/.gitmodules runtime/.gitignore design-system/a/b/.gitattributes
      designs/.GitAttributes .GITIGNORE
    ].each do |path|
      assert_equal [ "is outside the design repo's allowed folders" ],
                   Designs::LeakGuard.new.check([ change(path) ]).map(&:reason), "#{path} must be refused"
    end
  end

  test "a file that merely resembles a git configuration file is not one" do
    paths = %w[designs/gitattributes.html designs/old.gitignore designs/.gitkeep]
    assert_empty Designs::LeakGuard.new.check(paths.map { change(_1) })
  end

  test "a path that is not plainly inside a folder is refused, however it is spelled" do
    %w[designs/../CLAUDE.md designs/./a.html ./designs/a.html /designs/a.html designs//a.html designs/].each do |path|
      assert_equal [ "is outside the design repo's allowed folders" ],
                   Designs::LeakGuard.new.check([ change(path) ]).map(&:reason), "#{path} must be refused"
    end
  end

  test "a change that breaks several rules is reported once for each, in the order of the rules" do
    guard = Designs::LeakGuard.new(forbidden_texts: [ LIBRARY ], secrets: [ "ghp_SECRET123" ])
    violations = guard.check([ change(".claude/skill.md", "#{LIBRARY} ghp_SECRET123") ])
    assert_equal [ "is outside the design repo's allowed folders",
                   "contains a passage from the Flosis library",
                   "contains a stored credential" ], violations.map(&:reason)
    assert_equal [ ".claude/skill.md" ], violations.map(&:path).uniq
  end

  test "every forbidden text counts, and a text shorter than a passage never matches" do
    other = "Never set body copy in light grey on white because contrast fails for a quarter of readers."
    guard = Designs::LeakGuard.new(forbidden_texts: [ nil, "too short to be a passage", LIBRARY, other ])

    quoted = "Never set body copy in light grey on white because contrast fails"
    assert_equal [ "contains a passage from the Flosis library" ], guard.check([ change("designs/a.html", quoted) ]).map(&:reason)
    assert_empty guard.check([ change("designs/a.html", "too short to be a passage") ])
  end

  # A prompt is longer than twelve words, and a design may quote any twelve of
  # them: the guard has to know every window of a library text, overlapping,
  # not only the one that starts at its first word.
  test "a passage is caught wherever it starts in a long library text" do
    windows = LIBRARY.split.each_cons(12).map { _1.join(" ") }
    assert_equal 5, windows.size
    guard = Designs::LeakGuard.new(forbidden_texts: [ LIBRARY ])

    windows.each_with_index do |quoted, index|
      assert_equal [ "contains a passage from the Flosis library" ],
                   guard.check([ change("designs/a.html", quoted) ]).map(&:reason),
                   "the twelve words from word #{index + 1} on must be refused: #{quoted}"
    end
  end

  test "a passage must lie within one change: two files do not add up to one" do
    first_half = "Always pair the display serif with a quiet"
    second_half = "grotesk and keep body copy at sixteen pixels"
    guard = Designs::LeakGuard.new(forbidden_texts: [ LIBRARY ])
    assert_empty guard.check([ change("designs/a.html", first_half), change("designs/b.html", second_half) ])
  end

  test "a violation names the path and the rule, never the library text it found" do
    violations = Designs::LeakGuard.new(forbidden_texts: [ LIBRARY ]).check([ change("designs/a.html", LIBRARY) ])
    assert_equal 1, violations.size
    assert_not_includes violations.inspect, "grotesk"
  end

  test "a secret counts from eight characters on, once its surrounding whitespace is stripped" do
    seven = Designs::LeakGuard.new(secrets: [ "  abcdefg\n" ])
    assert_empty seven.check([ change("designs/a.html", "x abcdefg y") ])

    eight = Designs::LeakGuard.new(secrets: [ "  abcdefgh\n" ])
    assert_equal [ "contains a stored credential" ], eight.check([ change("designs/a.html", "x abcdefgh y") ]).map(&:reason)
  end

  # The project hands over every credential it stores, not just one.
  test "every stored secret is guarded, not only the first or the last" do
    secrets = %w[ghp_FIRST_SECRET1 ghp_SECOND_SECRET2 ghp_THIRD_SECRET3]
    guard = Designs::LeakGuard.new(secrets: secrets)

    secrets.each_with_index do |secret, index|
      in_text = guard.check([ change("designs/a.html", "token=#{secret}") ])
      assert_equal [ "contains a stored credential" ], in_text.map(&:reason), "secret ##{index + 1} in the text must be refused"

      in_name = guard.check([ change("designs/#{secret}.html") ])
      assert_equal [ "contains a stored credential" ], in_name.map(&:reason), "secret ##{index + 1} in a file name must be refused"
      assert_equal [ "[withheld]" ], in_name.map(&:path)

      reported = (in_text + in_name).inspect
      assert_not_includes reported, secret
    end
  end

  test "a credential in a file name is refused too, and the violation withholds the name" do
    guard = Designs::LeakGuard.new(secrets: [ "ghp_SECRET123" ])
    inside = guard.check([ change("designs/ghp_SECRET123.html") ])
    outside = guard.check([ change(".claude/ghp_SECRET123.md") ])

    assert_equal [ "contains a stored credential" ], inside.map(&:reason)
    assert_equal [ "is outside the design repo's allowed folders", "contains a stored credential" ], outside.map(&:reason)
    reported = (inside + outside).inspect
    assert_not_includes reported, "ghp_SECRET123"
    assert_equal [ "[withheld]" ], (inside + outside).map(&:path).uniq
  end

  test "text and file names that are not valid UTF-8 are read, not raised on" do
    guard = Designs::LeakGuard.new(forbidden_texts: [ LIBRARY ], secrets: [ "ghp_SECRET123" ])
    broken = "\xFF\xFE ghp_SECRET123 #{LIBRARY} \xC3"
    assert_equal [ "contains a passage from the Flosis library", "contains a stored credential" ],
                 guard.check([ change("designs/a.html", broken) ]).map(&:reason)

    assert_empty guard.check([ change("designs/caf\xE9.html") ])
    assert_equal [ "is outside the design repo's allowed folders" ], guard.check([ change(".claude/caf\xE9.md") ]).map(&:reason)
  end

  # The guard holds every credential and library passage in plain text: a log
  # line, an exception, a console or a failed assertion that prints it must not
  # print them.
  test "inspecting the guard shows how much it holds, never what it holds" do
    guard = Designs::LeakGuard.new(forbidden_texts: [ LIBRARY ], secrets: [ "ghp_SECRET123", "ghp_OTHER4567", nil, "short" ])

    assert_equal "#<Designs::LeakGuard secrets=2 passages=5>", guard.inspect

    [ guard.inspect, guard.to_s, guard.pretty_inspect, [ guard ].inspect, { guard: guard }.to_s ].each do |shown|
      assert_not_includes shown, "ghp_SECRET123"
      assert_not_includes shown, "ghp_OTHER4567"
      assert_not_includes shown.downcase, "grotesk"
    end
  end
end
