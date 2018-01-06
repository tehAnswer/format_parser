class FormatParser::MOOVParser
  include FormatParser::IOUtils

  class Atom < Struct.new(:at, :atom_size, :atom_type, :path, :children, :atom_fields)
    def to_s
      "%s (%s): %d bytes at offset %d" % [atom_type, path.join('.'), atom_size, at]
    end

    def as_json(*a)
      members.each_with_object({}) do |member_name, o|
        o[member_name] = public_send(member_name).as_json(*a)
      end
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

    ftyp_atom = find_first_atom_by_path(atom_tree, 'ftyp')
    file_type = ftyp_atom.atom_fields.fetch(:major_brand)

    FormatParser::FileInformation.video(
      file_type: file_type[0..2], # MP4 files have "mp42" where 2 is the sub-version, not very useful. m4a have "M4A "
      intrinsics: atom_tree,
    )
  end

  private

  def find_first_atom_by_path(atoms, *atom_path)
    type_to_find = atom_path.shift
    requisite = atoms.find {|e| e.atom_type == type_to_find }
    
    return requisite if atom_path.empty?
    return nil unless requisite
    find_first_atom_by_path(requisite.children || [], *atom_path)
  end

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
    num_brands = (atom_size - 8 - 8) / 4
    ret = {
      major_brand: io.read(4).unpack('a4').first,
      minor_version: to_binary_coded_decimal(io.read(4)),
      compatible_brands: (1..num_brands).map { io.read(4).unpack('a4').first },
    }
  end

  def parse_tkhd_atom(io, _)
    tkhd_info_bites = [
      :version, :C1,
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
      :track_width, :N1,
      :track_height, :N1,
    ]
    dict = read_and_unpack_dict(io, tkhd_info_bites)
    dict[:matrix_structure] = dict[:matrix_structure].unpack('N9')
    dict
  end

  def parse_mdhd_atom(io, _)
    mdhd_info_bites = [
      :version, :C1,
      :flags, :a3,
      :ctime, :N1,
      :mtime, :N1,
      :tscale, :N1,
      :duration, :N1,
      :language, :n1,
      :quality, :n1,
    ]
    read_and_unpack_dict(io, mdhd_info_bites)
  end

  def parse_mvhd_atom(io, _)
    mvhd_info_bites = [
      :version, :C1,
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
    dict = read_and_unpack_dict(io, mvhd_info_bites)
    dict[:matrix_structure] = dict[:matrix_structure].unpack('N9')
    dict
  end

  def parse_dref_atom(io, _)
    dref_info_bites = [
      :version, :C1,
      :flags, :a3,
      :num_entries, :N1,
    ]
    dict = read_and_unpack_dict(io, dref_info_bites)
    num_entries = dict[:num_entries]
    entries = (1..num_entries).map do
      dref_entry_bites = [
        :size, :N1,
        :type, :a4,
        :version, :C1,
        :flags, :a3,
      ]
      entry = read_and_unpack_dict(io, dref_entry_bites)
      entry[:data] = io.read(entry[:size] - 12)
      entry
    end
    dict[:entries] = entries
    dict
  end

  def parse_elst_atom(io, _)
    elst_info_bites = [
      :version, :C1,
      :flags, :a3,
      :num_entries, :N1,
    ]
    dict = read_and_unpack_dict(io, elst_info_bites)
    num_entries = dict[:num_entries]
    entries = (1..num_entries).map do
      entry_bites = [
        :track_duration, :N1,
        :media_time, :N1,
        :media_rate, :N1,
      ]
      read_and_unpack_dict(io, entry_bites)
    end
    dict[:entries] = entries
    dict
  end

  def parse_hdlr_atom(io, atom_size)
    atom_size -= 8
    hdlr_info_bites = [
      :version, :C1,
      :flags, :a3,
      :component_type, :a4,
      :component_subtype, :a4,
      :component_manufacturer, :a4,
      :component_flags, :a4,
      :component_flags_mask, :a4,
    ]
    atom_data = StringIO.new(io.read(atom_size))
    dict = read_and_unpack_dict(atom_data, hdlr_info_bites)
    dict[:component_name] = atom_data.read
    dict
  end

  def parse_atom_fields_per_type(io, atom_size, atom_type)
    if respond_to?("parse_#{atom_type}_atom", including_privates = true)
      send("parse_#{atom_type}_atom", io, atom_size)
    else
      nil # We can't look inside this leaf atom
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
