class FormatParser::MOOVParser
  include FormatParser::IOUtils

  class Atom < Struct.new(:at, :atom_size, :atom_type, :parent_types, :children, :atom_fields)
    def to_s
      "%s (%s): %d bytes, %s" % [atom_type, parent_types.join('.'), atom_size, atom_fields]
    end
  end

  # Atoms (boxes) that are known to only contain children, no data fields
  KNOWN_BRANCH_ATOM_TYPES = %w( moov mdia trak clip edts minf dinf stbl udta meta)

  # Atoms (boxes) that are known to contain both leaves and data fields
  KNOWN_BRANCH_AND_LEAF_ATOM_TYPES = %w( meta ) # the udta.meta thing used by iTunes

  SIZEOF = lambda { |pattern|
    bytes_per_element = {
      'v' => 2, # 16bit uints
      'n' => 2,
      'V' => 4, # 32bit uints
      'N' => 4,
      'C' => 1,
      'a' => 1,
      'x' => 1,
    }
    pattern.scan(/[^\d]\d+/).map do |pattern|
      unpack_code = pattern[0]
      num_repetitions = pattern[1..-1].to_i
      bytes_per_element.fetch(unpack_code) * num_repetitions
    end.inject(&:+)
  }
  MAX_ATOMS_AT_LEVEL = 128 # Limit how many atoms we scan in sequence, to prevent derailments

  def information_from_io(io)
    return nil unless matches_moov_definition?(io)

    # Now we know we are in a MOOV, so go back and parse out the atom structure.
    # Parsing out the atoms does not read their contents - at least it doesn't
    # for the atoms we consider opaque (one of which is the "mdat" atom which
    # will be the prevalent part of the file body). We do not parse these huge
    # atoms - we skip over them and note where they are located.
    io.seek(0)

    # We have to tell the parser how far we are willing to go within the stream.
    # Knowing that we will bail out early anyway we will permit a large read. The
    # branch parse calls will know the maximum size to read from the parent atom
    # size that gets parsed just before.
    max_read = 0xFFFFFFFF
    atom_tree = extract_atom_stream(io, max_read)

    ftyp_atom = atom_tree.find {|e| e.atom_type == 'ftyp' }
    file_type = ftyp_atom.atom_fields.fetch(:major_brand)

    FormatParser::FileInformation.video(
      file_type: file_type,
      intrinsics: atom_tree,
    )
  end

  private

  # An MPEG4/MOV/M4A will start with the "ftyp" atom. The atom must have a length
  # of at least 8 (to accomodate the atom size and the atom type itself) plus the major
  # and minor version fields. If we cannot find it we can be certain this is not our file.
  def matches_moov_definition?(io)
    maybe_atom_size, maybe_ftyp_atom_signature = safe_read(io, 8).unpack('N1a4')
    minimum_ftyp_atom_size = 4 + 4 + 4 + 4
    maybe_atom_size >= minimum_ftyp_atom_size && maybe_ftyp_atom_signature == 'ftyp'
  end

  def read_and_unpack_dict(io, properties_to_packspecs)
    keys, packspecs = properties_to_packspecs.partition.with_index { |_, i| i.even? }
    unpack_pattern = packspecs.join
    blob_size = SIZEOF[unpack_pattern]
    blob = io.read(blob_size)
    unpacked_values = blob.unpack(packspecs.join)
    Hash[keys.zip(unpacked_values)]
  end

  def to_binary_coded_decimal(bcd_string)
    bcd_string.insert(0, '0') if bcd_string.length.odd?
    [bcd_string].pack('H*').unpack('C*')
  end

  def parse_ftyp_atom(io, atom_size)
    # Subtract 8 for the atom_size+atom_type,
    # and 8 once more for the major_brand and minor_version. The remaining
    # numbr of bytes is reserved for the compatible brands, 4 bytes per
    # brand.
    num_brands = atom_size - 8 - 8
    ret = {
      major_brand: io.read(4).unpack('a4').first,
      minor_version: to_binary_coded_decimal(io.read(4)),
      compatible_brands: io.read(4 * num_brands).unpack('a4*'),
    }
  end

  def parse_tkhd_atom(io, _)
    tkhd_info_bites = [
      :version, :a1,
      :flags, :a3,
      :ctime, :N1,
      :mtime, :N1,
      :trak_id, :N1,
      :reserved_1, :a4,
      :duration, :N1,
      :reserved_2, :a8,
      :layer, :n1,
      :alternate_group, :n1,
      :volume, :n1,
      :reserved_3, :a2,
      :matrix_structure, :a36,
      :track_width, :a4,
      :track_height, :a4,
    ]
    read_and_unpack_dict(io, tkhd_info_bites)
  end

  def parse_mdhd_atom(io, _)
    mdhd_info_bites = [
      :version, :a1,
      :flags, :a3,
      :ctime, :N1,
      :mtime, :N1,
      :tscale, :N1,
      :duration, :N1,
      :language, :N1,
      :quality, :N1,
    ]
    read_and_unpack_dict(io, mdhd_info_bites)
  end

  def parse_mvhd_atom(io, _)
    mvhd_info_bites = [
      :version, :a1,
      :flags, :a3,
      :ctime, :N1,
      :mtime, :N1,
      :tscale, :N1,
      :duration, :N1,
      :preferred_rate, :N1,
      :reserved, :a10,
      :matrix_structure, :a36,
      :preview_time, :N1,
      :preview_duration, :N1,
      :poster_time, :N1,
      :selection_time, :N1,
      :selection_duration, :N1,
      :current_time, :N1,
      :next_trak_id, :N1,
    ]
    read_and_unpack_dict(io, mvhd_info_bites)
  end

  def parse_atom_fields_per_type(io, atom_size, atom_type)
    if respond_to?("parse_#{atom_type}_atom", including_privates = true)
      send("parse_#{atom_type}_atom", io, atom_size)
    else
      :opaque
    end
  end

  # Recursive descent parser - will drill down to atoms which
  # we know are permitted to have leaf/branch atoms within itself,
  # and will attempt to recover the data fields for leaf atoms
  def extract_atom_stream(io, max_read, current_branch = [])
    initial_pos = io.pos
    atoms = []
    MAX_ATOMS_AT_LEVEL.times do
      atom_pos = io.pos

      if atom_pos - initial_pos >= max_read
        break
      end

      size_and_type = io.read(4+4)
      if size_and_type.to_s.bytesize < 8
        break
      end

      atom_size, atom_type = size_and_type.unpack('Na4')

      # TODO: handle overlarge atoms (atom_size == 1 and the 64 bits right after is the size)
      children, fields = if KNOWN_BRANCH_AND_LEAF_ATOM_TYPES.include?(atom_type)
        parse_atom_children_and_data_fields(io, atom_size, atom_type)
      elsif KNOWN_BRANCH_ATOM_TYPES.include?(atom_type)
        [extract_atom_stream(io, atom_size - 8, current_branch + [atom_type]), nil]
      else # Assume leaf atom
        [nil, parse_atom_fields_per_type(io, atom_size, atom_type)]
      end

      atoms << Atom.new(atom_pos, atom_size, atom_type, current_branch + [atom_type], children, fields)

      io.seek(atom_pos + atom_size)
    end
    atoms
  end

  FormatParser.register_parser_constructor self
end
