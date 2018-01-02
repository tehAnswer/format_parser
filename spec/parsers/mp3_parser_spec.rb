require 'spec_helper'

describe FormatParser::MP3Parser do
  it 'parses an MP3 sample file' do
    parse_result = subject.information_from_io(File.open(fixtures_dir + '/MP3/fixture.mp3', 'rb'))

    expect(parse_result.file_nature).to eq(:audio)
    expect(parse_result.file_type).to eq(:mp3)
    expect(parse_result.media_duration_frames).to eq(46433)
    expect(parse_result.num_audio_channels).to eq(2)
    expect(parse_result.audio_sample_rate_hz).to be_within(0.01).of(44100)
    expect(parse_result.media_duration_seconds).to be_within(0.01).of(1.05)
  end

end
