# A page of a project's published designs, under a short-lived grant:
# /<organization>/<project>/<grant>/design/<page>. The grant names the
# project and the slot (Designs::PreviewGrant); the organization and the
# project in the path are only there to be read. A lasting link sends whoever
# opened it here once they have signed in (Designs::PreviewEntriesController),
# and the Designs screen shows its work here. Nothing here asks who is signed
# in or touches the session: the sandboxed page's requests carry no session.
#
# The pages are Claude's, with scripts anyone who can push to the design repo
# can change, served from the app's own host. Every response is sandboxed:
# the browser runs the page as an opaque origin, which reaches none of the
# app's cookies, storage or pages. Only browsers that honour the sandbox are
# served (allow_browser's modern ones all do), and the Designs screen
# sandboxes its frame as well.
#
# Forgery protection is off: there is nothing to forge on a GET of a static
# file, and its cross-origin check would refuse the page's own scripts, which
# the sandboxed page fetches from another origin than its own.
class Designs::PreviewsController < ActionController::Base
  allow_browser versions: :modern
  skip_forgery_protection

  POLICY = "sandbox allow-scripts allow-forms allow-popups allow-modals; frame-ancestors 'self'".freeze
  RUN_OUT = "This link to the designs has run out. Open the designs again from Flosis.".freeze

  before_action :set_headers

  def show
    project, slot = Designs::PreviewGrant.read(params[:grant])
    return render(plain: RUN_OUT, status: :not_found) unless project

    folder = Designs::Publisher.new(project, nil).slot_folder(slot)
    path = params[:path].to_s
    return head(:not_found) unless folder&.directory? && servable?(path)

    file = folder.join(path)
    if inside?(file, folder) && file.directory?
      # A page's relative links resolve against its folder: a folder opens at its slash.
      return redirect_to(slashed(request.path), status: :moved_permanently) unless asked_with_slash?

      file = file.join("index.html")
    end
    return head(:not_found) unless inside?(file, folder) && file.file?

    if stale?(last_modified: file.mtime, etag: [ file.to_s, file.size ])
      send_file file, disposition: :inline, type: Rack::Mime.mime_type(file.extname, "application/octet-stream")
    end
  rescue Designs::Publisher::Error, ArgumentError
    head :not_found
  end

  private

  def set_headers
    response.headers.merge!(
      "Content-Security-Policy" => POLICY,
      # The sandboxed page is an origin of its own: its fetches of its own files are cross-origin.
      "Access-Control-Allow-Origin" => "*",
      # The grant is in every path: never hand it to another site.
      "Referrer-Policy" => "no-referrer",
      "X-Robots-Tag" => "noindex, nofollow",
      "X-Content-Type-Options" => "nosniff"
    )
  end

  # No dotfile or dot folder (half-published .staging- and .old- copies among
  # them), no step out, and nothing a file name cannot hold.
  def servable?(path)
    path.split("/").none? { |segment| segment.start_with?(".") || segment.include?("\0") }
  end

  # There, and inside the slot's folder once links are followed.
  def inside?(file, folder)
    return false unless file.exist?

    real = file.realpath.to_s
    base = folder.realpath.to_s
    real == base || real.start_with?("#{base}/")
  end

  # Whether the path was asked for with its slash. Rails takes the slash off
  # request.path before routing; the path as asked keeps it.
  def asked_with_slash?
    request.original_fullpath.split("?", 2).first.end_with?("/")
  end

  # The path with a slash, and the query it came with.
  def slashed(path)
    query = request.query_string
    query.empty? ? "#{path}/" : "#{path}/?#{query}"
  end
end
