# frozen_string_literal: true

require_relative "../tool"
require_relative "../file_list"
require_relative "../image_sniffer"
require_relative "../tool_result"

module Tools
  # Lets the model LOOK AT AN IMAGE already on disk (issue #451).
  #
  # file.read runs every body through TextNormalizer - correct for text, mojibake
  # for a PNG. There was no tool whose argument is a path and whose result is an
  # image, so a disk screenshot could only be seen by loading it into some MCP
  # server and screenshotting THAT. This is the missing producer: resolve the path
  # through the SAME FileList read grant/consent rules file.read uses, sniff the
  # real type from the magic bytes (not the extension), and return a ToolResult
  # the Harness already routes through ImageDelivery (spill/inline for a vision
  # profile, a plain path for a text profile - doc/mcp_images_design.md).
  #
  # The Image carries `reference` (the model's own workdir path), so delivery
  # points at the original instead of spilling a duplicate copy of bytes the model
  # can open directly. Disk only - a URL image is web.fetch's job.
  class FileImageTool < Tool
    def initialize(file_list)
      @file_list = file_list
      super(
        name: "file.image",
        description: "Returns an image file from disk to the model as pixels " \
          "(or, for a model without vision, as a reachable path). " \
          "Paths are relative to the working directory and go through " \
          "the same read-grant rules as file.read. The type is sniffed " \
          "from the bytes, so the extension does not have to be right. " \
          "Use it to look at a screenshot or any image already in the " \
          "working directory; use file.read for text.",
        parameters: {
          type: "object",
          properties: {
            path: {
              type: "string",
              description: "Path to the image file (relative to the working directory)"
            }
          },
          required: ["path"]
        }
      )
    end

    def execute(args)
      path  = @file_list.resolve(args["path"])
      shown = @file_list.display_path(path)

      unless @file_list.readable?(path)
        result = @file_list.grant_access(path, :r, purpose: "to look at this image")
        return Tool.denial_error(
          "error: access denied for '#{shown}'",
          result) unless Tool.granted?(result)
      end

      unless File.file?(path)
        status(:fail, "#{shown} (not found)")
        return "error: file not found: #{shown}"
      end

      # A byte container (doc/encoding_design.md): read the raw bytes and let the
      # sniffer decide what they are. Never TextNormalizer - that is the very bug
      # this tool exists to avoid.
      bytes = File.binread(path)
      mime  = ImageSniffer.sniff(bytes)
      unless mime
        status(:fail, "#{shown} (not a recognized image)")
        return "error: '#{shown}' is not a recognized image " \
          "(read its bytes for PNG/JPEG/GIF/BMP/ICO signatures). " \
          "If it is text, use file.read."
      end

      status(:ok, "#{shown} (#{mime})")
      image = ToolResult::Image.new(
        server: "file.image",
        tool: "image",
        mime_type: mime,
        bytes:,
        reference: shown)
      ToolResult.new(
        text: "image #{shown} (#{mime}, #{bytes.bytesize} bytes)",
        images: [image])
    end
  end
end
