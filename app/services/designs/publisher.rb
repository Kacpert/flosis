require "cgi"
require "fileutils"
require "find"
require "open3"
require "securerandom"
require "tmpdir"

# Puts a branch of a project's design repo where the app serves it from
# (Designs::PreviewsController): DESIGNS_PREVIEW_ROOT, which no web server
# serves on its own, a folder per project named by a random token, and in it a
# folder per slot.
#
#   <root>/<token>/master/       master
#   <root>/<token>/REC-1/        a task's approved design
#   <root>/<token>/wip/REC-1/    a task's work in progress
#   <root>/<token>/wip/setup/    the design system being set up
#
# Links name the organization and the project, never the token: lasting ones
# ask whoever opens them to sign in, and send them on under a short-lived
# grant (#url, #grant_url). What is published is still kept to static web
# files, in case the root ever sits where a web server reaches it.
class Designs::Publisher
  # What may name a slot: master, a task's key, work in progress under wip/, or
  # a design thread's branch under design/. A slot becomes folders in the
  # document root, so it is never a path of its own: no dots, no leading or
  # doubled slashes, nothing after a newline. A bare "wip" or "design" is
  # refused too: it would replace that folder and every slot in it.
  SLOT = %r{\A(master|wip/setup|wip/[A-Za-z0-9_-]+|design/[A-Za-z0-9_-]+|(?!(?:wip|design)\z)[A-Za-z0-9_-]+)\z}

  # Anything pushed to the design repo reaches the docroot, where Apache honours nested .htaccess and PHP runs as the Rails user.
  SERVABLE_EXTENSIONS = %w[
    html htm css js mjs json map svg png jpg jpeg gif webp avif ico woff woff2 ttf otf txt md pdf mp4 webm
  ].freeze

  # Apache's mod_mime maps a handler by any extension in a name, so shell.php.html would run as PHP.
  SCRIPT_EXTENSIONS = %w[
    php php3 php4 php5 php6 php7 php8 phtml phar pht phps cgi fcgi pl py sh asp aspx jsp shtml shtm stm
  ].freeze

  # What a context id may be made of, the same for a dimension and a value
  # (the design repo's README says so). A link carries contexts as they are.
  CONTEXT = /\A[A-Za-z0-9_-]+\z/

  # The longest an organization's or a project's name is in a link.
  NAME_LIMIT = 30

  # A publish that cannot go ahead: the project has no folder for its design
  # repo yet, or a branch's files could not be unpacked into the document root.
  # Also raised in production when the preview root or host is not set.
  class Error < StandardError; end

  class << self
    # Blank counts as unset: an empty root would be the working directory.
    def root
      Pathname(setting("DESIGNS_PREVIEW_ROOT") { Rails.root.join("tmp/designs_preview") }).expand_path
    end

    def base_url
      setting("DESIGNS_PREVIEW_URL") { "http://localhost:3000" }.sub(%r{/+\z}, "")
    end

    # A name as a link writes it: letters, digits, - and _, cut to NAME_LIMIT,
    # with the stand-in when nothing is left of it.
    def label(name, stand_in)
      name.to_s.parameterize.first(NAME_LIMIT).sub(/[-_]+\z/, "").presence || stand_in
    end

    private

    # The variable, or in development and test the default the block gives.
    # Production has none: it must say where previews live, and the links
    # Jira gets must name the app's own host, which serves them.
    def setting(name)
      value = ENV[name].presence
      return value if value
      raise Error, "#{name} is not set, and production has no default for it" if Rails.env.production?

      yield
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
  # The new copy is unpacked into a private folder beside the slot, then swapped
  # in with two renames inside the token folder: the old copy is moved aside and
  # the new one renamed into its place. Apache never sees a half-written folder,
  # but between the two renames the slot is briefly absent. A failed publish puts
  # the old copy back.
  #
  # Raises Error, before the repo is touched, for a project with no folder of its
  # own: asked for one, the repo would make it (and save it) just to fail.
  #
  # Beside the branch's files go two things that are never committed: the
  # screens it has, as __flosis/screens.json for the runtime, and, given the
  # commit a thread is based on, each changed screen marked up against it, as
  # designs/<context>/<screen>.changes.html for the Changes view.
  def publish!(branch, slot, base: nil)
    slot = check_slot!(slot)
    raise Error, "the project has no design repo folder yet, so there is nothing to publish" unless stored_workspace_dir

    repo.synchronize do
      sha = repo.head(branch) || raise(ArgumentError, "the design repo has no branch #{branch}")
      folder = token_folder!
      staging = folder.join(".staging-#{SecureRandom.hex(8)}")
      begin
        unpack(sha, into: staging)
        strip_unservable!(staging)
        write_screens!(staging)
        write_changes!(staging, base) if base
        open_up!(staging)
        swap!(staging, folder.join(slot))
      ensure
        FileUtils.rm_rf(staging)
      end
      folder.join(slot)
    end
  end

  # Whether the slot has been published, so that a link into it leads to a
  # page. Only the disk is asked: nothing is made, the token included.
  def published?(slot)
    slot_folder(slot)&.directory? || false
  end

  # Where the slot is published, or nil while the project has no token.
  def slot_folder(slot)
    slot = check_slot!(slot)
    folder = project.design_preview_token.presence
    folder && self.class.root.join(folder, slot)
  end

  # Takes a slot down, as a task's old names are when it gets its Jira key. A
  # slot with nothing published is left as it is.
  def unpublish!(slot)
    slot = check_slot!(slot)
    folder = project.design_preview_token.presence
    return unless folder

    locked { FileUtils.rm_rf(self.class.root.join(folder, slot)) }
  end

  # A lasting link, for Jira and for people to keep: to the project's designs
  # (master) at /<organization>/<project>/design/<page>, or to a task's last
  # approved version at /<organization>/<project>/<key>/design/<page>. Whoever
  # opens one signs in, and must be someone the Workshop shows the project to
  # (Designs::PreviewEntriesController). Work in progress has none.
  #
  # The slot must be one publish! would take. The page is escaped a segment at
  # a time, so a space, #, ? or % in a file name still makes a working link. A
  # page that leaves its slot (a "." or ".." segment, a leading "/") and a
  # context that is not a context id (CONTEXT) are refused: these links reach Jira.
  def url(slot, path = "index.html", ctx: [])
    slot = check_slot!(slot)
    raise ArgumentError, "#{slot} is work in progress, which has no lasting link" if slot.start_with?("wip/")

    link(slot == Designs::Repo::MASTER ? "design" : "#{slot}/design", path, ctx)
  end

  # The page under a short-lived grant for the slot, where it is served
  # sandboxed (Designs::PreviewsController): where a lasting link sends whoever
  # opened it, and where the Designs screen shows its work.
  def grant_url(slot, path = "index.html", ctx: [])
    link("#{Designs::PreviewGrant.issue(project, check_slot!(slot))}/design", path, ctx)
  end

  # Gives the project a new token and moves its previews under it, which kills
  # every link under the old one. The folder moves first: if the process dies
  # between the two steps, the old links are dead rather than still open.
  #
  # With wait: false, a repo whose lock another holds raises Repo::Busy before
  # anything changes: a web request must not wait behind a job.
  def rotate_token!(wait: true)
    locked(wait: wait) do
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

  def check_slot!(slot)
    slot = slot.to_s
    raise ArgumentError, "#{slot.inspect} is not a preview slot" unless SLOT.match?(slot)

    slot
  end

  # A path inside the slot, as the repo lists its files: relative, and never
  # with a "." or ".." segment. ../wip/REC-1/x.html under an approved slot
  # would put work in progress in a Jira link.
  def check_page!(path)
    path = path.to_s
    if path.start_with?("/") || path.split("/", -1).any? { |segment| %w[. ..].include?(segment) }
      raise ArgumentError, "#{path.inspect} is not a page inside the slot"
    end

    path
  end

  def check_context!(value)
    value = value.to_s
    raise ArgumentError, "#{value.inspect} is not a context id (letters, digits, _ and -)" unless CONTEXT.match?(value)

    value
  end

  # Under the repo's lock only for a project that has a folder of its own, where
  # a clone can exist and a publish can be running. For any other project the
  # lock would make its folders (and give it a workspace_dir), which rotating
  # the links of a project that never turned Designs on must not do.
  def locked(wait: true, &block)
    return yield unless repo && stored_workspace_dir

    repo.synchronize(wait: wait, &block)
  end

  # The folder on the project's row, never the instance's idea of it, for the
  # same reason as the token. It matters more here: asked for the folder of a
  # project that has none, Repo makes a default one under ~/work/clients and
  # saves it, so an instance that has not heard of a folder the row has would
  # replace it. The reload also leaves the instance, which the Repo asks, current.
  def stored_workspace_dir
    project.reload.workspace_dir.presence
  end

  # The organization and the project, as links name them.
  def names
    "#{self.class.label(project.workspace&.name, "organization")}/#{self.class.label(project.name, "project")}"
  end

  # /<organization>/<project>/<within>/<page>, with the contexts.
  def link(within, path, ctx)
    page = check_page!(path).split("/", -1).map { |segment| CGI.escapeURIComponent(segment) }.join("/")
    link = "#{self.class.base_url}/#{names}/#{within}/#{page}"
    contexts = Array(ctx).map { |value| check_context!(value) }
    contexts.empty? ? link : "#{link}?ctx=#{contexts.join(",")}"
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
  # The folder is 0700 until open_up! has set the modes: the raw tree, with
  # whatever is still to be stripped from it, is not readable by Apache.
  def unpack(sha, into:)
    Dir.mktmpdir("designs-publish") do |tmp|
      tarball = File.join(tmp, "export.tar")
      GitRunner.run!("archive", "--format=tar", "-o", tarball, sha, chdir: repo.root)
      FileUtils.mkdir(into, mode: 0o700)
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
  # - files whose extension is not in SERVABLE_EXTENSIONS, in any case;
  # - files with a SCRIPT_EXTENSIONS segment anywhere after the first dot, so a
  #   script cannot hide behind an extension that is allowed (shell.php.html).
  #
  # Find does not follow links, and ignore_error: false makes an unreadable
  # folder raise instead of being skipped with whatever it holds. Whatever Find
  # is told to prune has just been deleted, so it must not look at it again.
  def write_screens!(dir)
    FileUtils.mkdir_p(dir.join("__flosis"))
    File.write(dir.join("__flosis/screens.json"), screens_in(dir).as_json.to_json)
  end

  def write_changes!(dir, base)
    before = Designs::Screens.new(paths: repo.ls_files(base, "designs/"), reader: ->(path) { repo.read_file(base, path) })
    changes = Designs::Changes.new(base: before, head: screens_in(dir), root: "../../")
    changes.changed.each do |change|
      File.write(dir.join("designs", change[:context], "#{change[:screen]}.changes.html"),
                 changes.marked_html(change[:context], change[:screen]))
    end
  end

  # The screens of an unpacked, stripped copy, read from the copy itself.
  def screens_in(dir)
    reader = ->(path) { file = dir.join(path); file.file? ? file.read : nil }
    Designs::Screens.new(paths: Dir.glob("designs/*/*.html", base: dir.to_s), reader: reader)
  end

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
    !name.start_with?(".") && !script_named?(name) &&
      SERVABLE_EXTENSIONS.include?(File.extname(name).delete_prefix(".").downcase)
  end

  # Whole segments only: php-guide.html and php.html are not scripts, a.PHP5.css is.
  def script_named?(name)
    name.split(".").drop(1).any? { |segment| SCRIPT_EXTENSIONS.include?(segment.downcase) }
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
