require 'spec_helper'

describe FormatParser::MOOVParser do

  def deep_print_atoms(atoms, output, swimlanes = [])
    return unless atoms

    mid = '├'
    last = '└'
    horz = '─'
    vert = '│'
    cdn = '┬'
    n_atoms = atoms.length
  
    atoms.each_with_index do |atom, i|
      is_last_child = i == (n_atoms - 1)
      has_children = atom.children && atom.children.any?
      connector = is_last_child ? last : mid
      connector_down = has_children ? cdn : horz
      connector_left = is_last_child ? ' ' : vert

      output << swimlanes.join << connector << connector_down << horz << atom.to_s << "\n"
      if af = atom.atom_fields
        af.each do |(field, value)|
          # Print data fields indented underneath the atom
          output << swimlanes.join << connector_left << ('   %s: %s' % [field, value.inspect]) << "\n"
        end
      end
      deep_print_atoms(atom.children, output, swimlanes + [connector_left])
    end
  end

  it 'parses an MP4 file and provides the necessary metadata' do
    fpath = fixtures_dir + '/MOOV/bmff.mp4'
    result = subject.information_from_io(File.open(fpath, 'rb'))

    expect(result).not_to be_nil
    expect(result.file_type).to eq('mp42')
    expect(result.intrinsics).not_to be_nil

    deep_print_atoms(result.intrinsics, $stderr)
  end

  it 'parses an M4A file and provides the necessary metadata'
  it 'parses a MOV file and provides the necessary metadata'
end
