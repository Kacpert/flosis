require "fileutils"
require "find"
require "open3"
require "tmpdir"

# The application as Claude reads it in a design turn: a copy of what the
# project's checkout has committed, made for one turn, read-only, and removed
# after it. Nothing runs in the checkout itself but git, and nothing that
# writes: the checkout is shared (the features scan pulls in it, and the
# legacy Elvium project's is a developer's own working copy), and what it does
# not track (.env, master.key) must never reach Claude, nor through it a
# pushed design.
#
# Each copy sits in a private folder of its own in the system's temp folder,
# named after PREFIX, and goes with it.
module Designs::AppCopy
  PREFIX = "designs-app".freeze

  class << self
    # Yields the copy's folder, or nil when there is nothing to copy, which is
    # logged: the project has no checkout, its checkout is a folder inside
    # another repository, or nothing is committed in it yet. The copy is
    # removed when the block is done, however it ends.
    def open(project)
      if (source = project.ai_codebase_path)
        holder = Dir.mktmpdir(PREFIX)
        copy = make(source, File.join(holder, "app"))
      else
        log("project #{project.id} has no app checkout of its own, so the turn runs without the app")
      end
      yield copy
    ensure
      remove(holder) if holder
    end

    # Removes the copies of turns that were killed: Solid Queue stops a worker
    # with exit!, which runs no ensure. Only this user's folders last touched
    # before older_than go, so a running turn's copy stays. Links are not
    # followed, and a failure is logged, never raised.
    def sweep(older_than:)
      Dir.glob(File.join(Dir.tmpdir, "#{PREFIX}*")).each do |holder|
        stat = File.lstat(holder)
        remove(holder) if stat.directory? && stat.uid == Process.euid && stat.mtime < older_than
      rescue StandardError => e
        log("could not sweep #{holder}: #{e.message}")
      end
    end

    private

    # The checkout's HEAD unpacked into dir, with plain files and folders only,
    # files 0444 and folders 0555, so that Claude's Edit and Write fail on it.
    # nil, with a warning, when it cannot be made.
    def make(source, dir)
      unless top_level?(source)
        log("#{source} is a folder inside another repository, not a checkout of its own, " \
            "so the turn runs without the app")
        return
      end

      tarball = "#{dir}.tar"
      GitRunner.run!("archive", "--format=tar", "-o", tarball, "HEAD", chdir: source)
      FileUtils.mkdir(dir, mode: 0o700)
      _, error, status = Open3.capture3({ "LC_ALL" => "C" }, "tar", "-xf", tarball, chdir: dir)
      raise "tar could not unpack it: #{error.strip}" unless status.success?

      File.delete(tarball)
      strip_links!(dir)
      seal!(dir)
      dir
    rescue StandardError => e
      log("no copy of #{source} for Claude to read, so the turn runs without the app: #{e.message}")
      nil
    end

    # git answers for the repository a folder is in, wherever that is: in a
    # folder inside another repository (Flosis's own code, say), git archive
    # would copy that repository's files.
    def top_level?(source)
      File.realpath(GitRunner.run!("rev-parse", "--show-toplevel", chdir: source).strip) == File.realpath(source)
    end

    # A link the app's repo tracks would lead Claude's tools out of the copy
    # (to the live checkout's .env, say), and seal! would follow it. Find does
    # not. Find looks at what it yielded once the block is done, so what was
    # deleted is pruned.
    def strip_links!(dir)
      Find.find(dir, ignore_error: false) do |path|
        stat = File.lstat(path)
        next if stat.file? || stat.directory?

        File.unlink(path)
        Find.prune
      end
    end

    def seal!(dir)
      Find.find(dir, ignore_error: false) do |path|
        File.chmod(File.lstat(path).directory? ? 0o555 : 0o444, path)
      end
    end

    # Writable again first: nothing in a folder that cannot be written to can
    # be deleted.
    def remove(holder)
      FileUtils.chmod_R("u+w", holder)
      FileUtils.rm_rf(holder)
    rescue StandardError => e
      log("could not remove #{holder}: #{e.message}")
    end

    def log(message)
      Rails.logger.warn("[#{name}] #{message}")
    end
  end
end
