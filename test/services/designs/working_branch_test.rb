require "test_helper"

class Designs::WorkingBranchTest < ActiveSupport::TestCase
  setup { @dir = Pathname(Dir.mktmpdir("wb")) }
  teardown { FileUtils.remove_entry(@dir) }

  def write(path, body)
    FileUtils.mkdir_p(@dir.join(path).dirname)
    File.write(@dir.join(path), body)
  end

  def branch(slug = "REC-1")
    Designs::WorkingBranch.new(@dir, slug)
  end

  # The links the Designs screen builds from what the branch reads. Publisher
  # refuses a context id and a page it cannot link to, so a screen built from
  # a value the branch let through would be a 500.
  def publisher
    project = projects(:jira_project)
    project.update!(design_preview_token: "t0k")
    Designs::Publisher.new(project, nil)
  end

  test "reads contexts and their defaults" do
    write("designs/contexts.json", { dimensions: [
      { id: "permissions", name: "Permissions", values: [ { id: "admin", name: "Admin" }, { id: "viewer", name: "Viewer" } ], default: "viewer" },
      { id: "plan", name: "Plan", values: [ { id: "pro", name: "Pro" } ] },
      { id: "empty", name: "Empty", values: [] }
    ] }.to_json)
    branch = Designs::WorkingBranch.new(@dir, "REC-1")
    assert_equal %w[permissions plan], branch.dimensions.map { _1["id"] }
    assert_equal %w[viewer pro], branch.default_ctx
  end

  test "a broken contexts file means no contexts" do
    write("designs/contexts.json", "{ nope")
    assert_empty Designs::WorkingBranch.new(@dir, "REC-1").dimensions
  end

  test "the entry page is the manifest's first existing screen" do
    write("designs/jobs/index.html", "<p>jobs</p>")
    write("designs/tasks/REC-1.json", { screens: [
      { path: "designs/gone.html", title: "Gone" },
      { path: "designs/jobs/index.html", title: "Jobs", contexts: [ "admin" ] },
      { path: "../secrets.html", title: "Escape" }
    ] }.to_json)
    branch = Designs::WorkingBranch.new(@dir, "REC-1")
    assert_equal [ "designs/jobs/index.html" ], branch.screens.map { _1["path"] }
    assert_equal "designs/jobs/index.html", branch.entry_path
  end

  test "without a manifest the entry page is the index" do
    assert_equal "index.html", Designs::WorkingBranch.new(@dir, "REC-1").entry_path
  end

  # A name that is missing is the id, so a pill is never blank. The directory
  # may be a String as well as a Pathname.
  test "a dimension reads as its id, name, values and default" do
    write("designs/contexts.json", { dimensions: [
      { id: "permissions", name: "Permissions", values: [ { id: "admin", name: "Admin" }, { id: "viewer" } ] },
      { id: "plan", values: [ { id: "pro", name: "Pro" } ], default: "pro" }
    ] }.to_json)
    assert_equal [
      { "id" => "permissions", "name" => "Permissions", "default" => "admin",
        "values" => [ { "id" => "admin", "name" => "Admin" }, { "id" => "viewer", "name" => "viewer" } ] },
      { "id" => "plan", "name" => "plan", "default" => "pro", "values" => [ { "id" => "pro", "name" => "Pro" } ] }
    ], Designs::WorkingBranch.new(@dir.to_s, "REC-1").dimensions
  end

  # The runtime only honours a default that is one of the dimension's values and
  # falls back to the first value otherwise; the screen has to agree with it.
  test "a default that is not a value of its dimension gives way to the first value" do
    contexts = [
      { id: "plan", values: [ { id: "free" }, { id: "pro" } ], default: "pro" },
      { id: "role", values: [ { id: "admin" }, { id: "viewer" } ], default: "ghost" },
      { id: "kind", values: [ { id: "a" }, { id: "b" } ], default: 5 },
      { id: "tier", values: [ { id: "x" }, { id: "y" } ], default: [ "y" ] },
      { id: "mode", values: [ { id: "light" }, { id: "dark" } ], default: nil }
    ]
    write("designs/contexts.json", { dimensions: contexts }.to_json)
    assert_equal %w[pro admin a x light], branch.default_ctx
  end

  # Ruling P2-R6: a context id goes into a preview link, and Publisher#url
  # refuses one that is not letters, digits, _ and - (the 500 would be the
  # whole screen). A dimension or a value named otherwise is not offered, and a
  # dimension left with no value is dropped like an empty one.
  test "a dimension or a value whose id is not a context id is dropped, and never a default" do
    write("designs/contexts.json", { dimensions: [
      { id: "plan", name: "Plan", default: "free plan",
        values: [ { id: "free plan", name: "Free" }, { id: "pro", name: "Pro" }, { id: "a,b", name: "Comma" } ] },
      { id: "who am i", name: "Spaces", values: [ { id: "admin", name: "Admin" } ] },
      { id: "role", name: "Role", values: [ { id: "../admin", name: "Slashes" }, { id: "viewer\n", name: "Newline" } ] },
      { id: "", name: "Blank", values: [ { id: "x", name: "X" } ] },
      { id: 7, name: "Number", values: [ { id: "x", name: "X" } ] },
      { id: "żółw", name: "Letters beyond ASCII", values: [ { id: "x", name: "X" } ] },
      { id: "tier_2", name: "Tier", values: [ { id: 3, name: "Number" }, { id: "free-tier", name: "Free" } ] }
    ] }.to_json)
    assert_equal %w[plan tier_2], branch.dimensions.map { _1["id"] }
    assert_equal [ %w[pro], %w[free-tier] ], branch.dimensions.map { |dimension| dimension["values"].map { _1["id"] } }
    assert_equal %w[pro free-tier], branch.default_ctx
    assert_nothing_raised { publisher.grant_url("wip/REC-1", branch.entry_path, ctx: branch.default_ctx) }
  end

  test "a screen reads as its path, title and contexts" do
    %w[a b c d].each { write("designs/#{_1}.html", "<p>#{_1}</p>") }
    write("designs/tasks/REC-1.json", { screens: [
      { path: "designs/a.html", title: "A", contexts: [ "admin", "not a context", 7, "viewer", "x,y", nil ] },
      { path: "designs/b.html" },
      { path: "designs/c.html", title: "  ", contexts: "admin" },
      { path: "designs/d.html", title: { en: "D" }, contexts: { admin: true }, notes: "left out" }
    ] }.to_json)
    assert_equal [
      { "path" => "designs/a.html", "title" => "A", "contexts" => %w[admin viewer] },
      { "path" => "designs/b.html", "title" => "designs/b.html", "contexts" => [] },
      { "path" => "designs/c.html", "title" => "designs/c.html", "contexts" => [] },
      { "path" => "designs/d.html", "title" => "designs/d.html", "contexts" => [] }
    ], branch.screens
  end

  # Ruling P2-R6: a screen's path goes into a preview link, and Publisher#url
  # refuses one that walks out of its slot. Only files under designs/, whole
  # segments only: a dot inside a name is the name.
  test "a screen is kept only when its path is a file under designs/ that stays where it says" do
    write("designs/jobs/index.html", "<p>jobs</p>")
    write("designs/..odd.html", "<p>odd</p>")
    write("designs/a.b.html", "<p>dots</p>")
    write("secrets.html", "<p>secret</p>")
    write("other/page.html", "<p>other</p>")
    write("designs-extra/page.html", "<p>extra</p>")
    kept = %w[designs/jobs/index.html designs/..odd.html designs/a.b.html]
    dropped = [
      "../secrets.html", "designs/../secrets.html", "designs/jobs/../../secrets.html", "designs/jobs/..",
      "designs/./jobs/index.html", "designs/jobs/./index.html", "./designs/jobs/index.html",
      "/designs/jobs/index.html", "/#{@dir}/designs/jobs/index.html", "#{@dir}/designs/jobs/index.html",
      "other/page.html", "designs-extra/page.html", "designs", "secrets.html", "index.html",
      "designs/gone.html", "designs/jobs/index.html/", "designs/a\u0000b.html", "", " designs/jobs/index.html", nil, 5,
      [ "designs/jobs/index.html" ], { path: "designs/jobs/index.html" }
    ]
    write("designs/tasks/REC-1.json", { screens: (dropped + kept).map { { path: _1, title: "T" } } }.to_json)
    assert_equal kept, branch.screens.map { _1["path"] }
    assert_equal "designs/jobs/index.html", branch.entry_path
    branch.screens.each { |screen| assert_nothing_raised { publisher.grant_url("wip/REC-1", screen["path"], ctx: screen["contexts"]) } }
  end

  # Ruling P2-R18: a screen is a page. A folder exists, and Publisher#url would
  # link to it, but it opens only when it happens to hold an index.html, and
  # the preview is a 403 otherwise. So a manifest entry that points at a folder
  # is dropped, with the trailing slash or without, and the entry page is the
  # first entry that is a file.
  test "a screen is a file, never a folder" do
    write("designs/jobs/index.html", "<p>jobs</p>")
    write("designs/empty/.keep", "")
    write("designs/tasks/REC-1.json", { screens: [
      { path: "designs/jobs", title: "Jobs folder" },
      { path: "designs/jobs/", title: "Jobs folder, slashed" },
      { path: "designs/empty/", title: "A folder with no index" },
      { path: "designs/", title: "Designs" },
      { path: "designs/jobs/index.html", title: "Jobs" }
    ] }.to_json)
    assert_equal %w[designs/jobs/index.html], branch.screens.map { _1["path"] }
    assert_equal "designs/jobs/index.html", branch.entry_path

    write("designs/tasks/REC-2.json", { screens: [ { path: "designs/jobs/", title: "Jobs" } ] }.to_json)
    assert_empty branch("REC-2").screens
    assert_equal "index.html", branch("REC-2").entry_path
  end

  test "a task reads its own manifest and no other" do
    write("designs/a.html", "<p>a</p>")
    write("designs/b.html", "<p>b</p>")
    write("designs/tasks/REC-1.json", { screens: [ { path: "designs/a.html", title: "A" } ] }.to_json)
    write("designs/tasks/REC-2.json", { screens: [ { path: "designs/b.html", title: "B" } ] }.to_json)
    assert_equal %w[designs/a.html], branch("REC-1").screens.map { _1["path"] }
    assert_equal %w[designs/b.html], branch("REC-2").screens.map { _1["path"] }
    assert_empty branch("REC-3").screens
    assert_equal "index.html", branch("REC-3").entry_path
  end

  # Both files are Claude's work. Whatever shape they come in, the screen opens.
  test "a file that is not what the prompt describes has nothing in it, and is no error" do
    write("designs/a.html", "<p>a</p>")
    [
      "", "   ", "null", "3", '"text"', "true", "[]", "{}", "[[], {}]", "{ nope", "{}}", "\xFF\xFE\x00", "[" * 500 + "]" * 500,
      '{"dimensions": "x", "screens": "x"}',
      '{"dimensions": null, "screens": null}',
      '{"dimensions": {"id": "a", "values": [{"id": "b"}]}, "screens": {"path": "designs/a.html"}}',
      '{"dimensions": [null, 1, "x", [], {}, {"id": "a"}, {"id": "a", "values": "x"}, {"id": "a", "values": {"id": "b"}},
                       {"id": "a", "values": [null, "b", [], {}, {"id": 7}]}],
        "screens": [null, 1, "designs/a.html", [], {}, {"path": 5}, {"path": null}, {"path": ["designs/a.html"]}]}'
    ].each do |body|
      FileUtils.mkdir_p(@dir.join("designs/tasks"))
      File.binwrite(@dir.join("designs/contexts.json"), body)
      File.binwrite(@dir.join("designs/tasks/REC-1.json"), body)
      assert_empty branch.dimensions, body.inspect
      assert_empty branch.default_ctx, body.inspect
      assert_empty branch.screens, body.inspect
      assert_equal "index.html", branch.entry_path, body.inspect
    end
  end

  test "a folder where a file should be is no file" do
    FileUtils.mkdir_p(@dir.join("designs/contexts.json"))
    FileUtils.mkdir_p(@dir.join("designs/tasks/REC-1.json"))
    assert_empty branch.dimensions
    assert_empty branch.screens
    assert_equal "index.html", branch.entry_path
  end

  # JSON carries bytes that are not UTF-8 inside a string, and the first regexp
  # or split to meet them raises.
  test "a name or a path with bytes that are not UTF-8 is left out, and is no error" do
    write("designs/ok.html", "<p>ok</p>")
    File.binwrite(@dir.join("designs/contexts.json"),
                  %({"dimensions":[{"id":"a\xFF","values":[{"id":"b"}]},
                                   {"id":"c","name":"N\xFF","values":[{"id":"d\xFF"},{"id":"e","name":"\xFF"}],"default":"d\xFF"}]}))
    FileUtils.mkdir_p(@dir.join("designs/tasks"))
    File.binwrite(@dir.join("designs/tasks/REC-1.json"),
                  %({"screens":[{"path":"designs/\xFF.html"},{"path":"designs/ok.html","title":"T\xFF","contexts":["x\xFF","y"]}]}))
    assert_equal [ { "id" => "c", "name" => "c", "default" => "e", "values" => [ { "id" => "e", "name" => "e" } ] } ], branch.dimensions
    assert_equal %w[e], branch.default_ctx
    assert_equal [ { "path" => "designs/ok.html", "title" => "designs/ok.html", "contexts" => %w[y] } ], branch.screens
  end
end
