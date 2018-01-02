class FormatParser::MP3Parser
  include FormatParser::IOUtils

  def information_from_io(io)
    io.seek(0)
    return
  end

  FormatParser.register_parser_constructor self
end
