ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "tmpdir"
require "fileutils"
require_relative "test_helpers/session_test_helper"
require_relative "test_helpers/design_repo_test_helper"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...

    # Project#ai_codebase_path only answers for a checkout that genuinely
    # exists, and the AI jobs skip a project that has none — so a test that
    # exercises one of those jobs has to give its project a real directory.
    def checkout!(project)
      dir = Dir.mktmpdir("ai-checkout")
      (@ai_checkouts ||= []) << dir
      project.update_columns(workspace_dir: dir)
      FileUtils.mkdir_p(project.repo_checkout_path)
      project.repo_checkout_path
    end

    teardown do
      @ai_checkouts&.each { |dir| FileUtils.remove_entry(dir) if File.exist?(dir) }
    end

    # Sets environment variables for the block (nil unsets one), then puts
    # back what was there. Credentials the machine holds (.env, the CLI's
    # config) are replaced this way, so a test never reads, or prints, a real one.
    def with_env(vars)
      previous = vars.keys.index_with { |name| ENV[name] }
      vars.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
      yield
    ensure
      previous&.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    end
  end
end
