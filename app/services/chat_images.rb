# Images a person adds to a task's AI chat (Kacper, 2026-11-19): kept on the
# message (ActiveStorage), and written where Claude reads them, one folder per
# chat session, so the message to Claude can name each file for its Read tool.
module ChatImages
  TYPES = { "image/png" => ".png", "image/jpeg" => ".jpg", "image/gif" => ".gif", "image/webp" => ".webp" }.freeze
  SIZE_LIMIT = 10.megabytes
  PER_MESSAGE = 10

  module_function

  # Under storage/, which a deploy keeps (a linked dir): an earlier message's
  # paths still work in a later turn. CHAT_IMAGES_DIR overrides it.
  def root
    ENV.fetch("CHAT_IMAGES_DIR") { File.join(Rails.root.join("storage").realpath.to_s, "chat_images") }
  end

  def dir(chat_session)
    File.join(root, chat_session.id.to_s)
  end

  # Why these uploads cannot go with a message, or nil: the message's own
  # validation, said before anything else is done with them.
  def refusal(files)
    return "At most #{PER_MESSAGE} images a message." if files.size > PER_MESSAGE

    bad = files.find { |file| !TYPES.key?(file.content_type.to_s) }
    return "#{bad.original_filename} is not a PNG, JPG, GIF or WebP image." if bad

    big = files.find { |file| file.size.to_i > SIZE_LIMIT }
    "#{big.original_filename} is over 10 MB." if big
  end

  # Writes the message's images to its session's folder; returns their paths.
  def write!(message)
    folder = dir(message.chat_session)
    FileUtils.mkdir_p(folder)
    message.images.each_with_index.map do |image, index|
      path = File.join(folder, "#{message.id}-#{index + 1}#{TYPES.fetch(image.content_type, "")}")
      File.binwrite(path, image.download)
      path
    end
  end

  # What Claude is told about them, after the person's message.
  def note(paths)
    one = paths.size == 1
    "The person attached #{one ? "an image" : "#{paths.size} images"} to this message. " \
      "Read #{one ? "it" : "each"} with the Read tool before you answer:\n#{paths.map { |path| "- #{path}" }.join("\n")}"
  end
end
