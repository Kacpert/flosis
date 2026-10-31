require "test_helper"

# lib/capistrano/tasks/setup.rake, run against a stand-in for Capistrano: its
# tasks are defined as Capistrano would define them, and run here with every
# upload kept in memory instead of reaching a server.
class CapistranoSetupTasksTest < ActiveSupport::TestCase
  ROOT = "/home/host/domains/preview.example/public_html".freeze

  # Capistrano's DSL, as far as setup.rake uses it.
  class StandIn
    attr_reader :uploads

    def initialize(settings)
      @settings = settings
      @tasks = {}
      @uploads = {}
      path = Rails.root.join("lib/capistrano/tasks/setup.rake").to_s
      instance_eval(File.read(path), path)
    end

    def run(name)
      instance_exec(&@tasks.fetch(name))
    end

    def namespace(_name)
      yield
    end

    def desc(_text); end

    def task(name, &block)
      @tasks[name] = block
    end

    def fetch(key, default = nil)
      @settings.fetch(key, default)
    end

    def on(_hosts)
      yield
    end

    def roles(*); end

    def upload!(io, path)
      @uploads[path] = io.read
    end

    def execute(*); end

    def abort(message)
      raise ArgumentError, message
    end
  end

  test "only Flosis may frame a preview: app.flosis.com, unless the setting names another origin" do
    assert_includes htaccess, %(Header always set Content-Security-Policy "frame-ancestors https://app.flosis.com")
    assert_includes htaccess(designs_preview_frame_ancestor: "https://staging.flosis.com"),
                    %(Header always set Content-Security-Policy "frame-ancestors https://staging.flosis.com")
  end

  # The origin goes into a quoted header value: anything but a bare https
  # origin would widen the policy or break the file, and the host with it.
  test "a frame ancestor that is not an https origin is refused, and nothing is uploaded" do
    [ "*", "", "http://app.flosis.com", "https://app.flosis.com/", "https://a.example https://b.example",
      %(https://app.flosis.com" always) ].each do |origin|
      cap = StandIn.new(designs_preview_document_root: ROOT, designs_preview_frame_ancestor: origin)
      assert_raises(ArgumentError, origin) { cap.run(:designs_preview_htaccess) }
      assert_empty cap.uploads, origin
    end
  end

  test "the preview host is HTTPS only, and serves .mjs as JavaScript" do
    content = htaccess
    assert_includes content, %(Header always set Strict-Transport-Security "max-age=31536000")
    assert_includes content, "AddType text/javascript .mjs"
  end

  # The rules are written as Apache reads them, backslashes and all.
  test "the rules that keep scripts and half-published copies unserved are still there, as written" do
    content = htaccess
    assert_includes content, "Options -Indexes -ExecCGI -Includes"
    assert_includes content, 'RewriteRule (^|/)\.(staging|old)- - [F,L]'
    assert_includes content, '<FilesMatch "(?i)\.(php[0-9]?|phtml|phar|pht|phps|cgi|fcgi|pl|py|sh|asp|aspx|jsp|shtml|shtm|stm)(\.|$)">'
  end

  # A link reads /<organization>/<project>/<token>/…, and the files are under
  # <token>/. A path that already starts with a token (the rewritten one, or a
  # link without names) is not rewritten again.
  test "the organization and the project in a link are dropped before the files are looked up" do
    content = htaccess
    assert_includes content, "RewriteCond $1 !^[A-Za-z0-9]{32}$"
    assert_includes content, "RewriteRule ^([^/]+)/[^/]+/([A-Za-z0-9]{32})/(.*)$ $2/$3 [L]"
    assert_operator content.index("[A-Za-z0-9]{32})/(.*)$ $2/$3"), :>, content.index("https://%{HTTP_HOST}"),
                    "plain HTTP is sent to HTTPS first"
  end

  private

  def htaccess(settings = {})
    cap = StandIn.new({ designs_preview_document_root: ROOT }.merge(settings))
    cap.run(:designs_preview_htaccess)
    cap.uploads.fetch("#{ROOT}/.htaccess")
  end
end
