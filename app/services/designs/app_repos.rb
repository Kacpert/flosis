require "find"

# The app's repositories as a setup run reads them (the Designs setup, feature
# by feature): each one the setup form names, as owner/name or
# owner/name@branch, cloned shallow at that branch (or the repository's
# default one) into the run's folder, without its .git or any link it tracks
# (on a shared host a link could reach Flosis's own files or another
# client's, as AppCopy knows), and left read-only: files 0444, folders 0555,
# so that Claude's Edit and Write fail on them. The
# project's GitHub token reads them through GitRunner, which never puts it on
# a command line; a public repository needs none.
#
# A repository that cannot be read is a note on the run; a run that can read
# none of them stops.
class Designs::AppRepos
  class Failure < StandardError; end

  NAME = %r{\A([\w.-]+/[\w.-]+)(?:@([\w./-]+))?\z}

  class << self
    # Test seam: where owner/name is cloned from. Set to nil, it is GitHub.
    attr_writer :url_for

    def url_for
      @url_for || ->(name) { "https://github.com/#{name}.git" }
    end
  end

  def initialize(setup)
    @setup = setup
    @project = setup.project
  end

  # Clones each repository afresh and returns [{ "role", "repo", "branch",
  # "dir" }] for those that were read.
  def fetch!
    unseal(root)
    FileUtils.rm_rf(root)
    FileUtils.mkdir_p(root)
    last = nil
    fetched = rows.each_with_index.filter_map do |(role, name, branch), index|
      dir = root.join("#{index + 1}-#{name.parameterize}")
      clone(name, branch, dir)
      { "role" => role, "repo" => name, "branch" => branch, "dir" => dir.to_s }
    rescue GitRunner::Error, SystemCallError => e
      last = reason(e)
      @setup.note!("Reading the repositories", "#{name}#{" @ #{branch}" if branch} could not be read: #{last}.")
      nil
    end
    raise Failure, "No app repository could be read#{": #{last}" if last}." if fetched.empty?

    fetched
  end

  # The folders an earlier fetch! left.
  def dirs
    root.directory? ? root.children.select(&:directory?).sort.map(&:to_s) : []
  end

  private

  def root = @setup.run_dir.join("apps")

  # [role, "owner/name", branch or nil] for each row the form saved.
  def rows
    Array(@project.design_app_repos).filter_map do |row|
      next unless row.is_a?(Hash) && (match = NAME.match(row["repo"].to_s.strip))

      [ row["role"].presence || "Repository", match[1], match[2] ]
    end
  end

  def clone(name, branch, dir)
    GitRunner.run!("clone", "--quiet", "--depth", "1", *([ "--branch", branch ] if branch), "--",
                   self.class.url_for.call(name), dir.to_s, chdir: root, token: ProjectCredentials.new(@project).github_token)
    FileUtils.rm_rf(dir.join(".git"))
    Find.find(dir.to_s) { |path| File.delete(path) if File.symlink?(path) }
    seal(dir)
  end

  def seal(dir)
    Find.find(dir.to_s) do |path|
      next if File.symlink?(path)

      File.chmod(File.directory?(path) ? 0o555 : 0o444, path)
    end
  end

  # A sealed folder's files cannot be removed until its folders are writable.
  def unseal(dir)
    return unless dir.exist?

    Find.find(dir.to_s) { |path| File.chmod(0o755, path) if File.directory?(path) && !File.symlink?(path) }
  end

  def reason(error)
    error.message.to_s.lines.last(2).join(" ").squish.delete_suffix(".").truncate(200)
  end
end
