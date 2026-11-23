require "test_helper"

# The task's file for the developer (Finish, 2026-11-21): tasks/<KEY>/<key>.md
# and its attachments, so "read tasks/SCRUM-70/scrum-70.md" is all their AI
# needs.
class TaskFileTest < ActiveSupport::TestCase
  LINK = "https://preview.example/elvium/SCRUM-70".freeze

  setup do
    @root = Pathname(Dir.mktmpdir("preview"))
    ENV["DESIGNS_PREVIEW_ROOT"] = @root.to_s
    ENV["DESIGNS_PREVIEW_URL"] = "https://preview.example"
    @project = projects(:jira_project)
    @project.update!(design_preview_token: "t0k", design_repo: "acme/designs")
    @task = @project.tasks.create!(name: "SCRUM-70 Add token calculations", external_reference: "SCRUM-70", external_type: "jira",
                                   external_url: "https://acme.atlassian.net/browse/SCRUM-70")
    @draft = @task.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, origin: "ai", version: 5, content: "## Costs\n\nIntro.")
    @draft.make_current!
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    ENV.delete("DESIGNS_PREVIEW_URL")
    FileUtils.remove_entry(@root)
  end

  def accept!
    DesignMerge.create!(project: @project, task: @task, sha: "a" * 40, title: "t", branch: "design/x", how: "manual",
                        merged_at: Time.current, slot: "accepted/7")
    folder = @root.join("t0k", "accepted/7", "__flosis")
    FileUtils.mkdir_p(folder)
    File.write(folder.join("screens.json"), { contexts: [ { id: "admin", name: "Admin" } ],
                                              screens: [ { id: "plans", context: "admin", name: "Plans" } ] }.to_json)
    File.write(folder.join("changes.json"), { own: [ [ "admin", "plans", "new" ] ], through: {} }.to_json)
  end

  test "the file starts with the task's links and carries the current version as Markdown" do
    accept!
    file = TaskFile.new(@task)
    section = Designs::DesignsSection.build(@task)

    assert_equal [ "SCRUM-70", "tasks/SCRUM-70", "tasks/SCRUM-70/scrum-70.md" ], [ file.key, file.folder, file.path ]
    assert_equal <<~MD.strip, file.markdown
      # SCRUM-70 Add token calculations

      Description v5 · #{@draft.created_at.strftime('%-d %b %Y')} · from Flosis
      - Jira: https://acme.atlassian.net/browse/SCRUM-70
      - Designs (sign in to Flosis): #{LINK}
      - Design code: https://github.com/acme/designs/commit/#{'a' * 40}
        The screens this task changed, in that repo: designs/admin/plans.html

      ## Costs

      Intro.

      #{section}
    MD
    assert_equal [ "tasks/SCRUM-70/scrum-70.md" ], file.files.keys
  end

  test "a task without a key is task-<id>, and without designs the header has no design lines" do
    task = @project.tasks.create!(name: "Local idea")
    task.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, origin: "ai", version: 1, content: "Do it.").make_current!
    file = TaskFile.new(task)

    assert_equal "tasks/task-#{task.id}/task-#{task.id}.md", file.path
    assert_equal "# Local idea\n\nDescription v1 · #{task.current_detail_draft.created_at.strftime('%-d %b %Y')} · from Flosis\n\nDo it.",
                 file.markdown
  end

  test "attachments go beside it; big ones are listed, not copied" do
    @task.attachments.attach(io: StringIO.new("png"), filename: "shot.png", content_type: "image/png")
    @task.attachments.attach(io: StringIO.new("png2"), filename: "shot.png", content_type: "image/png")
    @task.attachments.attach(io: StringIO.new("x" * 20), filename: "video.mp4", content_type: "video/mp4")
    file = TaskFile.new(@task, max_attachment: 10)

    assert_equal [ "tasks/SCRUM-70/attachments/shot-2.png", "tasks/SCRUM-70/attachments/shot.png", "tasks/SCRUM-70/scrum-70.md" ],
                 file.files.keys.sort
    assert_equal "png", file.files["tasks/SCRUM-70/attachments/shot.png"]
    assert_includes file.markdown, "- Attachments: attachments/ (2 files)"
    assert_includes file.markdown, "Not copied (over the size limit): video.mp4, in Jira"
  end

  test "an HTML version is converted, and the Designs section is put back when missing" do
    accept!
    @task.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, origin: "manual", version: 6,
                              content: %(<p>See <a href="https://x.test/spec">the spec</a>.</p>)).make_current!
    markdown = TaskFile.new(@task).markdown

    assert_includes markdown, "See [the spec](https://x.test/spec).\n\n**Designs** · [Open the designs](#{LINK})"
    assert_includes markdown, "Description v6 ·"
  end
end
