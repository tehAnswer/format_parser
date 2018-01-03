class FormatParser::MP3Parser
  include FormatParser::IOUtils

  def information_from_io(io)
    io.seek(0)
    frame_header = safe_read(io, 13)
    # If the frame_header includes ID3, the header is wrapped in an ID3v2 tag
    parse_id3_v2_tag(io) if frame_header.include?("ID3")
  end

  def parse_id3_v2_tag(io)
    io.seek(0)
    # Parse the first few chunks of the ID3 tag. This gets tricky because
    # the nature of the tag is such that it's sometimes difficult to tell
    # exactly when there's no more tag left to read
  end

  def parse_id3_v1_tag(io)
    io.seek(0)
  end

  def parse_mp3_without_id3_tag(io)
    io.seek(0)
  end

  FormatParser.register_parser_constructor self
end
