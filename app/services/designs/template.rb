require "erb"
require "fileutils"

# What every project's design repo starts as: master's first commit. It opens
# from any static file server with no build step. runtime/flosis.js pulls in
# the <x-include> components and applies the contexts in the URL, and the
# project's base kit decides how the pages are styled.
#
# The template is lib/designs_template, rendered for one project:
#
# - an .erb file is rendered with `project` and `kit`, and loses its .erb;
# - design_system/theme.css.<kit> becomes design_system/theme.css, and the
#   other kits' themes are left out;
# - runtime/kits/<kit>.js becomes runtime/kit.js if the kit has one, and its
#   licence, runtime/kits/<kit>.LICENSE.txt, becomes runtime/kit-license.txt;
#   runtime/kits/ itself is never copied.
#
# runtime/kits/tailwind4.js is the Tailwind CSS browser build, vendored
# unmodified: dist/index.global.js of the npm package @tailwindcss/browser,
# version TAILWIND_VERSION, from
#   https://cdn.jsdelivr.net/npm/@tailwindcss/browser@<TAILWIND_VERSION>/dist/index.global.js
# (SHA-256 29edc4b76dac05a8c27bb9bdd0ec6d6506a2f55c1db24f11fa5b7f509142e6bf,
# the same bytes as in the package on the npm registry, pinned by
# test/services/designs/template_test.rb). That version because it is the
# tailwindcss-ruby version in Gold's Gemfile.lock: a design is compiled by the
# same Tailwind that builds Gold. Tailwind is MIT-licensed, and the MIT licence
# asks for its notice in every copy, so runtime/kits/tailwind4.LICENSE.txt is
# the same package's LICENSE, unmodified, from
#   https://cdn.jsdelivr.net/npm/@tailwindcss/browser@<TAILWIND_VERSION>/LICENSE
# To upgrade, replace both files with another version's, unmodified, then
# change TAILWIND_VERSION (the README states it), the SHA-256 here and its pin
# in the test.
module Designs::Template
  SOURCE = Rails.root.join("lib/designs_template")
  TAILWIND_VERSION = "4.2.1".freeze

  class << self
    # Writes the template for the project's base kit into dir, which is made
    # if need be. A kit the template has no theme for raises ArgumentError
    # before anything is written: a repo started without a theme stays that way.
    def render_into(dir, project:)
      kit = project.design_base_kit.to_s
      raise ArgumentError, "the design template has no theme for the base kit #{kit.inspect}" unless kits.include?(kit)

      Dir.glob("**/*", base: SOURCE.to_s).sort.each do |path|
        source = SOURCE.join(path)
        target = target_for(path, kit)
        next unless source.file? && target

        destination = File.join(dir, target)
        FileUtils.mkdir_p(File.dirname(destination))
        if path.end_with?(".erb")
          File.write(destination, ERB.new(source.read, trim_mode: "-").result_with_hash(project: project, kit: kit))
        else
          FileUtils.cp(source, destination)
        end
      end
    end

    private

    # The kits the template has a theme for. A kit is only ever compared with
    # these names, never put into a path, so it cannot reach outside SOURCE.
    def kits
      Dir.glob("theme.css.*", base: SOURCE.join("design_system").to_s).map { |name| name.delete_prefix("theme.css.") }
    end

    # Where a template file lands in the repo, or nil when it stays out.
    def target_for(path, kit)
      if path.start_with?("runtime/kits/")
        case path
        when "runtime/kits/#{kit}.js" then "runtime/kit.js"
        when "runtime/kits/#{kit}.LICENSE.txt" then "runtime/kit-license.txt"
        end
      elsif path.start_with?("design_system/theme.css.")
        "design_system/theme.css" if path == "design_system/theme.css.#{kit}"
      else
        path.delete_suffix(".erb")
      end
    end
  end
end
