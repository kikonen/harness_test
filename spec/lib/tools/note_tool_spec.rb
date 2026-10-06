# frozen_string_literal: true

require 'spec_helper'
require 'tools/note_tool'

RSpec.describe Tools::NoteTool do
  subject(:tool) { described_class.new }

  it 'has the ui.note name and a grant-focused description (issue #138)' do
    expect(tool.name).to eq('ui.note')
    expect(tool.description).to include('grant')
    expect(tool.namespace).to eq('ui')
  end

  it 'acknowledges a note' do
    out = tool.execute('text' => 'lib/ granted write (recursive)')
    expect(out).to start_with('ok: noted')
  end

  it 'strips surrounding whitespace from the note' do
    out = tool.execute('text' => "  lib/ granted write (recursive)  ")
    expect(out).to eq('ok: noted 30 chars')
  end

  it 'rejects an empty note' do
    expect(tool.execute('text' => '   ')).to eq('error: empty note')
    expect(tool.execute({})).to eq('error: empty note')
  end
end
