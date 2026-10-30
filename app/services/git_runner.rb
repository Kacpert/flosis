require "open3"

# The one way this app runs git. A token reaches git only through GIT_ASKPASS
# (bin/git-askpass), which reads it from the child's environment when GitHub
# asks for credentials. It is never put in a remote URL, in .git/config, on a
# command line, in a log line or in an exception message: every one of those
# outlives the job that needed it, where an environment variable dies with the
# process.
class GitRunner
  class Error < StandardError; end

  FILTERED = "[FILTERED]".freeze

  # Returns git's stdout and raises Error with git's own stderr when it exits
  # non-zero. Pass `token:` only for what talks to GitHub (clone, fetch, pull,
  # push); the rest of the commands never ask for credentials.
  def self.run!(*args, chdir:, token: nil)
    # The empty credential.helper wipes the helper list. Left alone, a
    # machine-wide helper (osxkeychain on a laptop) would answer in place of the
    # askpass script, and then be handed the token to keep.
    stdout, stderr, status = Open3.capture3(
      env(token), "git", "-c", "credential.helper=", *args, chdir: chdir.to_s
    )
    return stdout if status.success?

    # The token is never an argument, but git quotes its arguments back in what
    # it prints ("'x' is not a git command"), and this message ends up in logs
    # and in a column people read. So the whole message is filtered, rather
    # than trusted to be clean.
    message = "git #{args.first} failed: #{stderr}"
    message = message.gsub(token, FILTERED) if token.present?
    raise Error, message
  end

  # A job has no terminal, so git is never allowed to prompt at one: it fails
  # instead of waiting for an answer that cannot come. With a token, askpass
  # answers GitHub's questions; without one, a protected remote fails at once.
  def self.env(token)
    # Git's messages follow the host locale (Hostido may be Polish): one language for users, tests and parsers.
    vars = { "GIT_TERMINAL_PROMPT" => "0", "LC_ALL" => "C" }
    if token.present?
      vars["GIT_ASKPASS"] = Rails.root.join("bin", "git-askpass").to_s
      vars["FLOSIS_GIT_TOKEN"] = token
      vars["FLOSIS_GIT_USERNAME"] = "x-access-token"
    end
    vars
  end

  # No credentials in it, on purpose: see run! for how they get there instead.
  def self.github_url(repo)
    "https://github.com/#{repo}.git"
  end
end
