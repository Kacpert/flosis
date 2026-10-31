require "cgi"
require "fileutils"
require "find"
require "open3"
require "securerandom"
require "tmpdir"

# Puts a branch of a project's design repo where Apache serves it: the preview
# host's document root, a folder per project named by a long random token, and
# in it a folder per slot.
#
#   <root>/<token>/master/       master
#   <root>/<token>/REC-1/        a task's approved design
#   <root>/<token>/wip/REC-1/    a task's work in progress
#   <root>/<token>/wip/setup/    the design system being set up
#
# The token is the only lock on a preview: anyone with a link can open it.
# Rotating the token renames the project's folder, so every link sent so far
# stops working at once.
class Designs::Publisher
  # What may name a slot: master, a task's key, or work in progress under wip/.
  # A slot becomes folders in the document root, so it is never a path of its
  # own: no dots, no leading or doubled slashes, nothing after a newline. A bare
  # "wip" is refused too: it would replace the wip/ folder and every work in
  # progress in it.
  SLOT = %r{\A(master|wip/setup|wip/[A-Za-z0-9_-]+|(?!wip\z)[A-Za-z0-9_-]+)\z}

  # Anything pushed to the design repo reaches the docroot, where Apache honours nested .htaccess and PHP runs as the Rails user.
  SERVABLE_EXTENSIONS = %w[
    html htm css js mjs json map svg png jpg jpeg gif webp avif ico woff woff2 ttf otf txt md pdf mp4 webm
  ].freeze

  # A branch's files could not be unpacked into the document root.
  class Error < StandardError; end

  class << self
    # Blank counts as unset: an empty root would be the working directory.
    def root
      Pathname(ENV["DESIGNS_PREVIEW_ROOT"].presence || Rails.root.join("tmp/designs_preview")).expand_path
    end

    def base_url
      (ENV["DESIGNS_PREVIEW_URL"].presence || "http://localhost:3100").sub(%r{/+\z}, "")
    end
  end

  attr_reader :project, :repo

  # The repo can be nil for a Publisher that only builds links.
  def initialize(project, repo)
    @project = project
    @repo = repo
  end

  # Replaces what the slot shows with the branch as last committed, and returns
  # the slot's folder. What was uncommitted in a worktree is not published, and
  # neither is anything but static web files (see SERVABLE_EXTENSIONS).
  #
  # The new copy is unpacked into a folder of its own beside the slot, then the
  # old one is moved aside and the new one renamed into its place: both are
  # renames within the token folder, so Apache sees the old copy or the new one
  # and never a half-written folder. A failed publish leaves the old copy.
  def publish!(branch, slot)
    slot = slot.to_s
    raise ArgumentError, "#{slot.inspect} is not a preview slot" unless SLOT.match?(slot)

    repo.synchronize do
      sha = repo.head(branch) || raise(ArgumentError, "the design repo has no branch #{branch}")
      folder = token_folder!
      staging = folder.join(".staging-#{SecureRandom.hex(8)}")
      begin
        unpack(sha, into: staging)
        strip_unservable!(staging)
        open_up!(staging)
        swap!(staging, folder.join(slot))
      ensure
        FileUtils.rm_rf(staging)
      end
      folder.join(slot)
    end
  end

  # A link into a slot. Each context is escaped on its own, so the comma between
  # them is the only one in the list.
  def url(slot, path = "index.html", ctx: [])
    link = "#{self.class.base_url}/#{token}/#{slot}/#{path}"
    contexts = Array(ctx).map { |value| CGI.escape(value.to_s) }
    contexts.empty? ? link : "#{link}?ctx=#{contexts.join(",")}"
  end

  # Gives the project a new token and moves its previews under it, which kills
  # every link under the old one. The folder moves first: if the process dies
  # between the two steps, the old links are dead rather than still open.
  def rotate_token!
    locked do
      previous = project.reload.design_preview_token.presence
      token = SecureRandom.alphanumeric(32)
      from = previous && root.join(previous)
      to = root.join(token)

      moved = from&.exist?
      File.rename(from, to) if moved
      begin
        project.update_column(:design_preview_token, token)
      rescue StandardError
        File.rename(to, from) if moved
        raise
      end
      token
    end
  end

  private

  def root
    self.class.root
  end

  # Under the repo's lock only for a project that has a folder of its own, where
  # a clone can exist and a publish can be running. For any other project the
  # lock would make its folders (and give it a workspace_dir), which rotating
  # the links of a project that never turned Designs on must not do.
  def locked(&block)
    return yield unless repo && project.workspace_dir.present?

    repo.synchronize(&block)
  end

  # The token on the project's row. A link made before anything was published
  # gets one made on the spot, the same one the first publish then uses.
  def token
    project.design_preview_token.presence || stored_token!
  end

  # Read from the database, never from the instance: ensure_design_preview_token!
  # trusts the attribute it is called on, and an instance loaded before a
  # rotation, or before the first token, would write under a token that is no
  # longer the project's, or make a second one over the stored one. The instance
  # is reloaded, so it is current for whoever holds it afterwards.
  def stored_token!
    project.reload.ensure_design_preview_token!
  end

  # <root>/<token>, made if need be. Apache on the host cannot read what is
  # 0640, whatever umask made it, so the folder is opened explicitly.
  def token_folder!
    folder = root.join(stored_token!)
    FileUtils.mkdir_p(folder)
    File.chmod(0o755, folder)
    folder
  end

  # A tar of the commit, unpacked into a new folder. The tar sits in the system
  # temp folder: nothing but the published files belongs in the document root.
  def unpack(sha, into:)
    Dir.mktmpdir("designs-publish") do |tmp|
      tarball = File.join(tmp, "export.tar")
      GitRunner.run!("archive", "--format=tar", "-o", tarball, sha, chdir: repo.root)
      FileUtils.mkdir(into)
      # tar runs in the folder, not with -C: the folder's path holds the
      # project's token, and an argument shows in the process list.
      _, error, status = Open3.capture3("tar", "-xf", tarball, chdir: into.to_s)
      raise Error, "tar could not unpack #{sha}: #{error.strip}" unless status.success?
    end
  end

  # Only static web files are published, so everything else is deleted from the
  # unpacked copy, before anything is chmodded or swapped in:
  #
  # - symlinks, and any other entry that is not a plain file or folder. Apache
  #   follows a symlink the host user owns, so one committed to the repo
  #   (designs/leak -> /etc/passwd, or the Rails config) would be served, and a
  #   chmod would follow it too and open up whatever it points at;
  # - dotfiles and dot folders at any depth (.htaccess, .user.ini, .git*), with
  #   everything in them;
  # - files whose extension is not in SERVABLE_EXTENSIONS, in any case.
  #
  # Find does not follow links, and ignore_error: false makes an unreadable
  # folder raise instead of being skipped with whatever it holds. Whatever Find
  # is told to prune has just been deleted, so it must not look at it again.
  def strip_unservable!(dir)
    Find.find(dir.to_s, ignore_error: false) do |path|
      next if path == dir.to_s

      name = File.basename(path)
      stat = File.lstat(path)
      if stat.directory?
        next unless name.start_with?(".")

        FileUtils.rm_r(path)
      else
        next if stat.file? && servable?(name)

        File.unlink(path)
      end
      Find.prune
    end
  end

  def servable?(name)
    !name.start_with?(".") && SERVABLE_EXTENSIONS.include?(File.extname(name).delete_prefix(".").downcase)
  end

  # Folders 0755 and files 0644, whatever umask made them: Apache on the host
  # cannot read what is 0640, and nothing served needs an executable bit.
  def open_up!(dir)
    Find.find(dir.to_s, ignore_error: false) do |path|
      File.chmod(File.lstat(path).directory? ? 0o755 : 0o644, path)
    end
  end

  def swap!(staging, target)
    # wip/ is made by the first work in progress, and opened like the rest.
    FileUtils.mkdir_p(target.dirname)
    File.chmod(0o755, target.dirname)

    aside = staging.dirname.join(".old-#{SecureRandom.hex(8)}")
    File.rename(target, aside) if target.exist?
    begin
      File.rename(staging, target)
    rescue StandardError
      File.rename(aside, target) if aside.exist?
      raise
    end
    FileUtils.rm_rf(aside)
  end
end
