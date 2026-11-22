require "tmpdir"

# A stand-in `claude` on the PATH, for tests that run ClaudeCliService end to
# end through a real child process. The source is Ruby; it gets JSON and
# unbuffered output for free.
module FakeClaudeBinTestHelper
  def with_fake_claude_bin(ruby_source)
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "claude")
      File.write(bin, "#!/usr/bin/env ruby\nrequire \"json\"\n$stdout.sync = true\n#{ruby_source}\n")
      File.chmod(0o755, bin)
      original = ENV["PATH"]
      ENV["PATH"] = "#{dir}:#{original}"
      begin
        yield
      ensure
        ENV["PATH"] = original
      end
    end
  end
end
