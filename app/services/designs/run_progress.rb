# Where the feature a setup run is building stands, as the browser's progress
# tool writes it (run_dir/progress.json): each screen being built, being
# checked against the app, or done. The progress screen reads it; nothing
# else does.
module Designs::RunProgress
  module_function

  # { screen => "building" | "checking" | "done" } for feature, or {} when the
  # file is missing, unreadable, or about another feature.
  def screens(setup, feature)
    return {} unless feature

    data = JSON.parse(setup.run_dir.join("progress.json").read)
    return {} unless data.is_a?(Hash) && data["feature"] == feature.key && data["screens"].is_a?(Hash)

    data["screens"].transform_keys(&:to_s).transform_values(&:to_s)
  rescue JSON::ParserError, SystemCallError
    {}
  end
end
