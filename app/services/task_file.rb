# A task for the developer who takes it over (Finish, Kacper, 2026-11-21):
# tasks/<KEY>/<key>.md and its attachments, on the task's branch in the app's
# repo, so "read tasks/SCRUM-70/scrum-70.md" is all a developer's AI needs.
#
# The file starts with the task's links (Jira; its designs, which ask whoever
# opens them to sign in to Flosis; the design repo's merge commits and the
# screens changed there, which an AI can read without signing in), then the
# task's current description as Markdown, with its Designs section put back
# when the version lost it. Only the task's own attachments go beside it; a
# big one is named instead of copied.
class TaskFile
  MAX_ATTACHMENT = 50.megabytes

  def initialize(task, max_attachment: MAX_ATTACHMENT)
    @task = task
    @max_attachment = max_attachment
  end

  def key = Designs::BranchNames.slug(@task)
  def folder = "tasks/#{key}"
  def path = "#{folder}/#{key.downcase}.md"

  # "v5", for the commit message; nil when the task has no description yet.
  def version = document && "v#{document.version}"

  # { path => contents }: the file, then each attachment that is copied.
  def files
    { path => markdown }.merge(attachments.to_h { |name, attachment| [ "#{folder}/attachments/#{name}", attachment.download ] })
  end

  def markdown
    text = Designs::DesignsSection.markdown(Designs::DesignsSection.with_section(@task, description))
    [ "# #{@task.name}", header.join("\n"), text.presence ].compact.join("\n\n")
  end

  private

  # The Details version the task is at, else its brief.
  def document
    @task.current_detail_draft || @task.current_brief
  end

  def description
    document&.content.presence || @task.description.to_s
  end

  def header
    lines = [ [ document && "#{document.is_a?(Brief) ? 'Brief' : 'Description'} #{version}", document&.created_at&.strftime("%-d %b %Y"),
                "from Flosis" ].compact.join(" · ") ]
    lines << "- Jira: #{jira_url}" if jira_url
    lines.concat(design_lines)
    copied = attachments
    lines << "- Attachments: attachments/ (#{copied.size} #{copied.size == 1 ? 'file' : 'files'})" if copied.any?
    lines << "  Not copied (over the size limit): #{too_big.join(', ')}, in Jira" if too_big.any?
    lines
  end

  def jira_url
    return @task.external_url if @task.external_url.present?

    site = ProjectCredentials.new(@task.project).jira_site
    "https://#{site}/browse/#{@task.external_reference}" if site.present? && @task.external_reference.present?
  end

  def design_lines
    accepted = Designs::AcceptedScreens.new(@task)
    return [] unless accepted.any?

    publisher = Designs::Publisher.new(@task.project, nil)
    repo = @task.project.design_repo.presence
    lines = [ "- Designs (sign in to Flosis): #{publisher.url(key, nil)}" ]
    if repo
      lines.concat(accepted.merges.map { |merge| "- Design code: https://github.com/#{repo}/commit/#{merge.sha}" })
      paths = accepted.own.map { |screen| "designs/#{screen[:context]}/#{screen[:screen]}.html" }
      lines << "  The screens this task changed, in that repo: #{paths.join(', ')}" if paths.any?
    end
    lines
  end

  # [[name, attachment]] small enough to copy, each under a name of its own.
  def attachments
    @attachments ||= begin
      taken = Set.new
      @task.attachments.select { |attachment| attachment.byte_size <= @max_attachment }.map do |attachment|
        [ unique(attachment.filename.sanitized, taken), attachment ]
      end
    end
  end

  def too_big
    @task.attachments.reject { |attachment| attachment.byte_size <= @max_attachment }.map { |attachment| attachment.filename.sanitized }
  end

  def unique(name, taken)
    base = File.basename(name, ".*")
    ext = File.extname(name)
    candidate = name
    n = 1
    candidate = "#{base}-#{n += 1}#{ext}" while taken.include?(candidate)
    taken << candidate
    candidate
  end
end
