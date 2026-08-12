#!/usr/bin/env ruby
# frozen_string_literal: true

require 'io/console'
require 'fileutils'
require 'time'
require 'zlib'
require 'stringio'

module Color
  ENABLED = $stdout.tty?

  RESET   = ENABLED ? "\e[0m"  : ''
  BOLD    = ENABLED ? "\e[1m"  : ''
  DIM     = ENABLED ? "\e[2m"  : ''
  REVERSE = ENABLED ? "\e[7m"  : ''

  BLUE    = ENABLED ? "\e[34m" : ''
  CYAN    = ENABLED ? "\e[36m" : ''
  GREEN   = ENABLED ? "\e[32m" : ''
  YELLOW  = ENABLED ? "\e[33m" : ''
  MAGENTA = ENABLED ? "\e[35m" : ''
  RED     = ENABLED ? "\e[31m" : ''
  GRAY    = ENABLED ? "\e[90m" : ''
  WHITE   = ENABLED ? "\e[97m" : ''

  BRIGHT_BLUE    = ENABLED ? "\e[94m"  : ''
  BRIGHT_CYAN    = ENABLED ? "\e[96m"  : ''
  BRIGHT_GREEN   = ENABLED ? "\e[92m"  : ''
  BRIGHT_YELLOW  = ENABLED ? "\e[93m"  : ''
  BRIGHT_MAGENTA = ENABLED ? "\e[95m"  : ''
  BRIGHT_RED     = ENABLED ? "\e[91m"  : ''
  ORANGE         = ENABLED ? "\e[38;5;208m" : '' # 256-color orange (Rust)
  LIGHT_BLUE     = ENABLED ? "\e[38;5;117m" : '' # 256-color light/sky blue (C/C++)

  def self.wrap(code, text)
    ENABLED ? "#{code}#{text}#{RESET}" : text
  end
end

module ZipPeek
  # Returns an array of {name:, size:, dir:} or raises on malformed input.
  def self.list(path)
    data = File.binread(path)
    eocd_sig = "\x50\x4b\x05\x06"
    eocd_index = data.rindex(eocd_sig)
    raise 'not a zip file (no End Of Central Directory found)' unless eocd_index

    eocd = data[eocd_index, 22]
    total_entries = eocd[10, 2].unpack1('v')
    cd_offset = eocd[16, 4].unpack1('V')

    entries = []
    offset = cd_offset
    total_entries.times do
      sig = data[offset, 4]
      break unless sig == "\x50\x4b\x01\x02"

      header = data[offset, 46]
      compressed_size = header[20, 4].unpack1('V')
      uncompressed_size = header[24, 4].unpack1('V')
      name_len = header[28, 2].unpack1('v')
      extra_len = header[30, 2].unpack1('v')
      comment_len = header[32, 2].unpack1('v')
      name = data[offset + 46, name_len]
      entries << {
        name: name,
        size: uncompressed_size,
        compressed_size: compressed_size,
        dir: name.end_with?('/')
      }
      offset += 46 + name_len + extra_len + comment_len
    end
    entries
  end
end

module TarGzPeek
  def self.list(path)
    entries = []
    Zlib::GzipReader.open(path) do |gz|
      loop do
        header = gz.read(512)
        break if header.nil? || header.length < 512 || header == "\x00" * 512

        name = header[0, 100].delete("\x00")
        break if name.empty?

        size_octal = header[124, 12].delete("\x00").strip
        size = size_octal.empty? ? 0 : size_octal.to_i(8)
        typeflag = header[156, 1]
        is_dir = typeflag == '5' || name.end_with?('/')

        entries << { name: name, size: size, dir: is_dir }

        # skip file content, padded to 512-byte boundary
        padded = (size + 511) / 512 * 512
        gz.read(padded) if padded.positive?
      end
    end
    entries
  end
end

class U
  QUIT_KEYS = ['q', 'Q', "\u0003", "\u0004"].freeze # q, Q, Ctrl-C, Ctrl-D
  HELP_KEYS = ['u', '?'].freeze
  TEXT_EXTENSIONS = %w[
    .txt .md .markdown .rb .py .js .ts .jsx .tsx .json .yml .yaml .toml
    .cfg .conf .ini .sh .bash .zsh .c .h .cpp .hpp .java .go .rs .php
    .html .htm .css .scss .xml .csv .log .gitignore .env .rdoc .rst
  ].freeze
  ARCHIVE_EXTENSIONS_ZIP = %w[.zip].freeze
  ARCHIVE_EXTENSIONS_TARGZ = %w[.tar.gz .tgz].freeze
  PREVIEW_MAX_BYTES = 64 * 1024
  FORCED_WIDTH = 150
  FORCED_HEIGHT = 50

  LANG_COLORS = {
    '.py' => :BLUE,
    '.js' => :YELLOW,
    '.jsx' => :YELLOW,
    '.rb' => :RED,
    '.c' => :LIGHT_BLUE,
    '.h' => :LIGHT_BLUE,
    '.cpp' => :LIGHT_BLUE,
    '.cc' => :LIGHT_BLUE,
    '.hpp' => :LIGHT_BLUE,
    '.rs' => :ORANGE
  }.freeze

  def initialize(start_path, resize: true, width: FORCED_WIDTH, height: FORCED_HEIGHT)
    @dir = File.expand_path(start_path)
    @dir = File.dirname(@dir) unless File.directory?(@dir)
    @index = 0
    @scroll = 0
    @show_hidden = false
    @marked = {}
    @message = nil
    @message_kind = :info
    @filter = nil
    @running = true
    @show_preview = true
    @show_help = false
    @clipboard = { mode: nil, paths: [] }
    @resize = resize
    @forced_width = width
    @forced_height = height
    reload
  end

  def run
    setup_screen
    while @running
      draw
      key = read_key
      handle_key(key)
    end
  ensure
    teardown_screen
  end

  private

  def setup_screen
    @stty_save = `stty -g 2>/dev/null`.strip
    system('stty raw -echo isig 2>/dev/null')
    print "\e[?1049h" # alternate screen buffer
    print "\e[?25l"   # hide cursor
    force_terminal_size if @resize
  end

  def force_terminal_size
    print "\e[8;#{@forced_height};#{@forced_width}t"
    $stdout.flush
    sleep 0.05
  end

  def teardown_screen
    print "\e[?25h"   # show cursor
    print "\e[?1049l" # leave alternate screen
    if @stty_save && !@stty_save.empty?
      system("stty #{@stty_save} 2>/dev/null")
    else
      system('stty sane 2>/dev/null')
    end
    $stdout.flush
  end

  def term_size
    rows, cols = IO.console.winsize
    rows = 24 if rows.nil? || rows.zero?
    cols = 80 if cols.nil? || cols.zero?
    [rows, cols]
  rescue StandardError
    [24, 80]
  end

  def reload
    entries = Dir.children(@dir).sort_by { |n| n.downcase }
    entries = entries.reject { |n| n.start_with?('.') } unless @show_hidden
    if @filter && !@filter.empty?
      entries = entries.select { |n| n.downcase.include?(@filter.downcase) }
    end
    @entries = entries.map do |name|
      full = File.join(@dir, name)
      stat = begin
        File.lstat(full)
      rescue StandardError
        nil
      end
      is_dir = stat ? stat.directory? : false
      {
        name: name,
        full: full,
        dir: is_dir,
        link: stat ? stat.symlink? : false,
        exec: stat ? stat.executable? : false,
        size: stat ? stat.size : 0,
        mtime: stat ? stat.mtime : nil,
        git_repo: is_dir && File.directory?(File.join(full, '.git'))
      }
    end
    @index = 0 if @index >= @entries.size
    @index = 0 if @index.negative?
    @marked.clear
  end

  def current
    @entries[@index]
  end

  def read_key
    c = STDIN.getc
    return nil if c.nil?
    return c unless c == "\e"

    if IO.select([STDIN], nil, nil, 0.05)
      c2 = STDIN.getc
      return "\e" if c2.nil?
      if c2 == '[' && IO.select([STDIN], nil, nil, 0.05)
        c3 = STDIN.getc
        return "\e[#{c3}"
      end
      return "\e#{c2}"
    end
    "\e"
  end

  def prompt(label)
    rows, = term_size
    print "\e[#{rows};1H\e[2K"
    print "\e[?25h"
    system('stty -raw echo 2>/dev/null')
    print Color.wrap(Color::CYAN, label)
    $stdout.flush
    line = STDIN.gets
    system('stty raw -echo isig 2>/dev/null')
    print "\e[?25l"
    line ? line.chomp : nil
  end

  def confirm(label)
    ans = prompt("#{label} (y/N): ")
    ans && ans.strip.downcase == 'y'
  end

  def set_message(text, kind = :info)
    @message = text
    @message_kind = kind
  end

  def handle_key(key)
    if key.nil? || QUIT_KEYS.include?(key)
      @running = false
      return
    end

    if @show_help
      @show_help = false
      return
    end

    if HELP_KEYS.include?(key)
      @show_help = true
      return
    end

    case key
    when 'j', "\e[B"
      move(1)
    when 'k', "\e[A"
      move(-1)
    when 'g'
      @index = 0
    when 'G'
      @index = [@entries.size - 1, 0].max
    when 'l', "\e[C", "\r", "\n"
      open_entry
    when 'h', "\e[D"
      go_up
    when ' '
      toggle_mark
    when 'd'
      delete_selection
    when 'x'
      cut_selection
    when 'y'
      copy_selection
    when 'p'
      paste_clipboard
    when 'r'
      rename_entry
    when 'n'
      new_file
    when 'N'
      new_dir
    when '.'
      @show_hidden = !@show_hidden
      reload
    when '/'
      f = prompt('/filter: ')
      @filter = (f && !f.empty?) ? f : nil
      reload
    when 'R'
      reload
      set_message('refreshed')
    when 'v'
      @show_preview = !@show_preview
    end
  end

  def move(delta)
    return if @entries.empty?
    @index = (@index + delta).clamp(0, @entries.size - 1)
  end

  def open_entry
    e = current
    return unless e
    if e[:dir]
      @dir = e[:full]
      reload
    else
      system('open', e[:full], out: File::NULL, err: File::NULL)
      set_message("opened #{e[:name]}")
    end
  end

  def go_up
    parent = File.dirname(@dir)
    return if parent == @dir
    prev = File.basename(@dir)
    @dir = parent
    reload
    idx = @entries.index { |e| e[:name] == prev }
    @index = idx if idx
  end

  def toggle_mark
    e = current
    return unless e
    if @marked.key?(e[:full])
      @marked.delete(e[:full])
    else
      @marked[e[:full]] = true
    end
    move(1)
  end

  def selection_targets
    @marked.empty? ? [current].compact : @entries.select { |e| @marked[e[:full]] }
  end

  def delete_selection
    targets = selection_targets
    return if targets.empty?

    names = targets.map { |e| e[:name] }.join(', ')
    return unless confirm("Delete #{targets.size} item(s): #{names}?")

    ok = 0
    targets.each do |e|
      if e[:dir] && !e[:link]
        FileUtils.rm_rf(e[:full])
      else
        FileUtils.rm_f(e[:full])
      end
      ok += 1
    rescue StandardError => ex
      set_message("error: #{ex.message}", :error)
    end
    set_message("deleted #{ok} item(s)", :warn) if @message.nil?
    reload
  end

  def cut_selection
    targets = selection_targets
    return if targets.empty?

    @clipboard = { mode: :cut, paths: targets.map { |e| e[:full] } }
    set_message("cut #{targets.size} item(s) — press p to paste", :warn)
    @marked.clear
  end

  def copy_selection
    targets = selection_targets
    return if targets.empty?

    @clipboard = { mode: :copy, paths: targets.map { |e| e[:full] } }
    set_message("copied #{targets.size} item(s) — press p to paste")
    @marked.clear
  end

  def paste_clipboard
    paths = @clipboard[:paths]
    if paths.nil? || paths.empty?
      set_message('clipboard is empty', :warn)
      return
    end

    mode = @clipboard[:mode]
    ok = 0
    paths.each do |src|
      next unless File.exist?(src)

      base = File.basename(src)
      dest = unique_dest(File.join(@dir, base))

      if File.expand_path(src) == File.expand_path(dest)
        set_message('refusing to paste onto itself', :error)
        next
      end

      begin
        if mode == :cut
          FileUtils.mv(src, dest)
        else
          if File.directory?(src) && !File.symlink?(src)
            FileUtils.cp_r(src, dest)
          else
            FileUtils.cp(src, dest)
          end
        end
        ok += 1
      rescue StandardError => ex
        set_message("error: #{ex.message}", :error)
      end
    end

    if mode == :cut
      @clipboard = { mode: nil, paths: [] } # cut is a one-shot move
    end

    set_message("pasted #{ok} item(s)") if @message.nil? || ok.positive?
    reload
  end

  def unique_dest(path)
    return path unless File.exist?(path)

    dir = File.dirname(path)
    ext = File.extname(path)
    base = File.basename(path, ext)

    candidate = File.join(dir, "#{base} copy#{ext}")
    n = 2
    while File.exist?(candidate)
      candidate = File.join(dir, "#{base} copy #{n}#{ext}")
      n += 1
    end
    candidate
  end

  def rename_entry
    e = current
    return unless e
    new_name = prompt("rename '#{e[:name]}' to: ")
    return if new_name.nil? || new_name.strip.empty?

    dest = File.join(@dir, new_name.strip)
    begin
      FileUtils.mv(e[:full], dest)
      set_message("renamed to #{new_name.strip}")
    rescue StandardError => ex
      set_message("error: #{ex.message}", :error)
    end
    reload
  end

  def new_file
    name = prompt('new file name: ')
    return if name.nil? || name.strip.empty?

    path = File.join(@dir, name.strip)
    begin
      FileUtils.touch(path)
      set_message("created #{name.strip}")
    rescue StandardError => ex
      set_message("error: #{ex.message}", :error)
    end
    reload
  end

  def new_dir
    name = prompt('new directory name: ')
    return if name.nil? || name.strip.empty?

    path = File.join(@dir, name.strip)
    begin
      FileUtils.mkdir_p(path)
      set_message("created #{name.strip}/")
    rescue StandardError => ex
      set_message("error: #{ex.message}", :error)
    end
    reload
  end

  def preview_kind(e)
    return :dir if e[:dir]

    name = e[:name].downcase
    return :zip if ARCHIVE_EXTENSIONS_ZIP.any? { |ext| name.end_with?(ext) }
    return :targz if ARCHIVE_EXTENSIONS_TARGZ.any? { |ext| name.end_with?(ext) }
    return :text if TEXT_EXTENSIONS.any? { |ext| name.end_with?(ext) }

    :none
  end

  def preview_header(e, width)
    return [Color.wrap(Color::GRAY, '(nothing selected)')] unless e

    kind_label = case preview_kind(e)
                 when :dir then 'directory'
                 when :zip then 'zip archive'
                 when :targz then 'tar.gz archive'
                 when :text then 'text preview'
                 else 'no preview'
                 end
    size_label = e[:dir] ? '' : "  #{human_size(e[:size])}"
    title = truncate(e[:name], [width - kind_label.length - size_label.length - 4, 4].max)
    [Color.wrap(Color::BOLD, title) + Color.wrap(Color::GRAY, "  · #{kind_label}#{size_label}")]
  end

  def preview_lines(e, width)
    return [] unless e

    case preview_kind(e)
    when :dir
      preview_dir_listing(e)
    when :zip
      preview_zip(e)
    when :targz
      preview_targz(e)
    when :text
      preview_text(e, width)
    else
      [Color.wrap(Color::GRAY, '(no preview available)')]
    end
  rescue StandardError => ex
    [Color.wrap(Color::RED, "preview error: #{ex.message}")]
  end

  def preview_dir_listing(e)
    children = Dir.children(e[:full]).sort_by(&:downcase).first(200)
    return [Color.wrap(Color::GRAY, '(empty directory)')] if children.empty?

    children.map do |name|
      full = File.join(e[:full], name)
      is_dir = File.directory?(full)
      is_dir ? Color.wrap(Color::BLUE, "#{name}/") : name
    end
  rescue StandardError
    [Color.wrap(Color::RED, 'cannot read directory')]
  end

  def preview_text(e, width)
    return [Color.wrap(Color::GRAY, '(file too large to preview)')] if e[:size] > 5 * 1024 * 1024

    raw = File.binread(e[:full], PREVIEW_MAX_BYTES)
    text = raw.dup.force_encoding('UTF-8')
    text = text.encode('UTF-8', invalid: :replace, undef: :replace, replace: '?') unless text.valid_encoding?

    lines = text.split("\n", -1).first(500)
    lines.map { |l| l.gsub("\t", '    ') }
  rescue StandardError
    [Color.wrap(Color::RED, 'cannot read file')]
  end

  def preview_zip(e)
    entries = ZipPeek.list(e[:full])
    header = [Color.wrap(Color::MAGENTA + Color::BOLD, "zip archive — #{entries.size} entries"), '']
    header + entries.first(300).map do |en|
      label = en[:dir] ? Color.wrap(Color::BLUE, en[:name]) : "#{en[:name]}  #{Color.wrap(Color::GRAY, human_size(en[:size]))}"
      label
    end
  rescue StandardError => ex
    [Color.wrap(Color::RED, "cannot read zip: #{ex.message}")]
  end

  def preview_targz(e)
    entries = TarGzPeek.list(e[:full])
    header = [Color.wrap(Color::MAGENTA + Color::BOLD, "tar.gz archive — #{entries.size} entries"), '']
    header + entries.first(300).map do |en|
      label = en[:dir] ? Color.wrap(Color::BLUE, en[:name]) : "#{en[:name]}  #{Color.wrap(Color::GRAY, human_size(en[:size]))}"
      label
    end
  rescue StandardError => ex
    [Color.wrap(Color::RED, "cannot read tar.gz: #{ex.message}")]
  end

  def human_size(bytes)
    return '   -' if bytes.nil?
    units = %w[B K M G T]
    size = bytes.to_f
    unit = 0
    while size >= 1024 && unit < units.size - 1
      size /= 1024
      unit += 1
    end
    unit.zero? ? format('%4d%s', size, units[unit]) : format('%4.1f%s', size, units[unit])
  end

  def name_color(e)
    return Color::MAGENTA if e[:dir] && e[:git_repo]
    return Color::BLUE if e[:dir]
    return Color::CYAN if e[:link]

    lang_color = lang_color_for(e[:name])
    return lang_color if lang_color

    return Color::GREEN if e[:exec]

    Color::WHITE
  end

  def lang_color_for(name)
    lower = name.downcase
    ext = LANG_COLORS.keys.find { |e| lower.end_with?(e) }
    return nil unless ext

    Color.const_get(LANG_COLORS[ext])
  end

  def draw
    rows, cols = term_size

    if @show_help
      draw_help(rows, cols)
      return
    end

    list_height = rows - 4 # title + path + separator + status

    preview_on = @show_preview && cols >= 60
    list_width = preview_on ? (cols / 2) : cols

    adjust_scroll(list_height)

    buf = +''
    buf << "\e[H\e[2J"

    clip_label =
      if @clipboard[:mode] == :cut
        Color.wrap(Color::YELLOW, " ✂ #{@clipboard[:paths].size}")
      elsif @clipboard[:mode] == :copy
        Color.wrap(Color::GREEN, " ⧉ #{@clipboard[:paths].size}")
      else
        ''
      end

    title = Color.wrap(Color::BOLD + Color::BRIGHT_MAGENTA, ' u ')
    hint = Color.wrap(Color::DIM + Color::BRIGHT_BLUE, '?help')
    buf << "\e[1;1H#{title}#{clip_label} #{Color.wrap(Color::BRIGHT_BLUE, truncate(@dir, list_width - 16))}  #{hint}\n\r"
    buf << Color.wrap(Color::BLUE, '─' * [cols, 1].max) << "\r\n"

    visible = @entries[@scroll, list_height] || []
    list_rows = []
    visible.each_with_index do |e, i|
      real_index = @scroll + i
      selected = real_index == @index
      marked = @marked.key?(e[:full])

      mark_glyph = marked ? Color.wrap(Color::YELLOW, '●') : ' '
      icon = e[:dir] ? '/' : ' '
      size = e[:dir] ? '   -' : human_size(e[:size])

      plain_prefix_len = "#{marked ? '●' : ' '} #{format('%-6s', size)}  ".length
      remaining_width = list_width - 1 - plain_prefix_len
      shown_name = truncate(e[:name] + icon, remaining_width)
      shown_name_colored = Color.wrap(name_color(e), shown_name)

      line_plain = "#{mark_glyph} #{Color.wrap(Color::GRAY, format('%-6s', size))}  #{shown_name_colored}"

      rendered = if selected
                   "\e[7m#{line_plain}\e[27m"
                 else
                   line_plain
                 end
      list_rows << rendered
    end
    (list_height - list_rows.size).times { list_rows << '' } if list_rows.size < list_height

    preview_rows = []
    if preview_on
      preview_width = cols - list_width - 3
      body = preview_lines(current, preview_width).first(list_height - 2)
      header = preview_header(current, preview_width)
      preview_rows = header + [''] + body
      preview_rows = preview_rows.map { |l| truncate_visible(l, preview_width) }
      (list_height - preview_rows.size).times { preview_rows << '' } if preview_rows.size < list_height
      preview_rows = preview_rows.first(list_height)
    end

    list_height.times do |i|
      left = list_rows[i] || ''
      left_padded = pad_visible(left, list_width - 1)
      if preview_on
        right = preview_rows[i] || ''
        sep = Color.wrap(Color::BLUE, '│')
        buf << "#{left_padded} #{sep} #{right}\r\n"
      else
        buf << "#{left_padded}\r\n"
      end
    end

    buf << Color.wrap(Color::BLUE, '─' * [cols, 1].max) << "\r\n"

    status = status_line
    buf << "\e[#{rows};1H\e[2K#{truncate_visible(status, cols - 1)}"

    print buf
    $stdout.flush
    @message = nil
  end

  # Full-screen help overlay
  def draw_help(rows, cols)
    sections = [
      ['NAVIGATION', [
        ['j / ↓', 'move down'],
        ['k / ↑', 'move up'],
        ['h / ←', 'parent directory'],
        ['l / → / ⏎', 'open dir / file / archive'],
        ['g', 'jump to top'],
        ['G', 'jump to bottom']
      ]],
      ['SELECTION', [
        ['space', 'toggle mark'],
        ['x', 'cut selection'],
        ['y', 'copy selection'],
        ['p', 'paste here'],
        ['d', 'delete selection']
      ]],
      ['FILE OPS', [
        ['r', 'rename entry'],
        ['n', 'new file'],
        ['N', 'new directory']
      ]],
      ['VIEW', [
        ['.', 'toggle hidden files'],
        ['/', 'filter entries'],
        ['R', 'refresh listing'],
        ['v', 'toggle preview'],
        ['u / ?', 'toggle this help']
      ]],
      ['OTHER', [
        ['q / Ctrl-C', 'quit']
      ]]
    ]

    box_width = [cols - 4, 60].max
    box_width = [box_width, cols - 2].min
    left_x = [(cols - box_width) / 2, 0].max

    content_width = box_width - 2   # space between the left and right border chars
    inner_width = content_width - 4 # minus 2-space paddingg

    num_cols = box_width >= 100 ? 2 : 1
    col_gap = num_cols > 1 ? 2 : 0
    col_width = (inner_width - col_gap) / num_cols

    columns = Array.new(num_cols) { [] }
    col_heights = Array.new(num_cols, 0)
    sections.each do |title_text, rows_data|
      target_idx = col_heights.each_index.min_by { |i| col_heights[i] }
      col = columns[target_idx]
      col << Color.wrap(Color::BOLD + Color::BRIGHT_BLUE, title_text)
      col << Color.wrap(Color::BLUE, '─' * [title_text.length, col_width - 1].min)
      rows_data.each do |key, desc|
        key_col = Color.wrap(Color::YELLOW + Color::BOLD, format('%-12s', key))
        col << truncate_visible("#{key_col} #{Color.wrap(Color::WHITE, desc)}", col_width)
      end
      col << ''
      col_heights[target_idx] += rows_data.size + 3
    end

    max_lines = columns.map(&:size).max || 0
    body_lines = []
    max_lines.times do |i|
      row = columns.map { |c| pad_visible(c[i] || '', col_width) }.join(' ' * col_gap)
      body_lines << row
    end

    buf = +''
    buf << "\e[H\e[2J"

    top_y = [(rows - (body_lines.size + 6)) / 2, 1].max

    border_top = "╭#{'─' * content_width}╮"
    border_bot = "╰#{'─' * content_width}╯"
    title_text = ' u — keybindings '
    title_padded = title_text.center(content_width)

    buf << "\e[#{top_y};#{left_x + 1}H" << Color.wrap(Color::BRIGHT_BLUE, border_top)
    buf << "\e[#{top_y + 1};#{left_x + 1}H│" << Color.wrap(Color::BOLD + Color::BRIGHT_MAGENTA, title_padded) << '│'
    buf << "\e[#{top_y + 2};#{left_x + 1}H├#{'─' * content_width}┤"

    body_lines.each_with_index do |line, i|
      y = top_y + 3 + i
      padded = pad_visible(line, inner_width)
      buf << "\e[#{y};#{left_x + 1}H" << Color.wrap(Color::BRIGHT_BLUE, '│') << "  #{padded}  " << Color.wrap(Color::BRIGHT_BLUE, '│')
    end

    footer_y = top_y + 3 + body_lines.size
    footer_text = 'press any key to close'.center(content_width)
    buf << "\e[#{footer_y};#{left_x + 1}H│" << Color.wrap(Color::DIM, footer_text) << '│'
    buf << "\e[#{footer_y + 1};#{left_x + 1}H" << Color.wrap(Color::BRIGHT_BLUE, border_bot)

    print buf
    $stdout.flush
  end

  def adjust_scroll(list_height)
    return if list_height <= 0
    if @index < @scroll
      @scroll = @index
    elsif @index >= @scroll + list_height
      @scroll = @index - list_height + 1
    end
    @scroll = 0 if @scroll.negative?
  end

  def status_line
    if @message
      color = case @message_kind
              when :error then Color::RED
              when :warn then Color::YELLOW
              else Color::GREEN
              end
      Color.wrap(color, @message)
    else
      count = @entries.size
      marked = @marked.size
      pos = count.zero? ? 0 : @index + 1
      hidden = @show_hidden ? 'on' : 'off'
      filt = @filter ? " filter:#{@filter}" : ''

      left = Color.wrap(Color::BRIGHT_CYAN, "#{pos}/#{count}") +
             Color.wrap(Color::GRAY, "  marked:#{marked}  hidden:#{hidden}#{filt}")
      help = Color.wrap(Color::DIM, '  j/k move  l/h in/out  space mark  x cut  y copy  p paste  d del  r ren  v preview  ?/u help  q quit')
      left + help
    end
  end

  def visible_length(str)
    str.gsub(/\e\[[0-9;]*m/, '').length
  end

  def truncate_visible(str, width)
    return str if width.nil? || width <= 0
    return str if visible_length(str) <= width
    plain = str.gsub(/\e\[[0-9;]*m/, '')
    plain[0, [width - 1, 0].max] + '…'
  end

  def pad_visible(str, width)
    return str if width.nil? || width <= 0
    len = visible_length(str)
    len >= width ? str : str + (' ' * (width - len))
  end

  def truncate(str, width)
    return str if width.nil? || width <= 0
    str.length > width ? str[0, [width - 1, 0].max] + '…' : str
  end
end

def print_usage
  puts <<~USAGE
    u — a minimal terminal file manager

    Usage:
      u                          open in your home directory (default)
      u [path]                   open in the given directory
      u --start PATH             same as above, explicit flag form
      u --width N --height N     override the forced terminal size (default 120x40)
      u --no-resize              don't force-resize the terminal at all
      u --help, -h               show this message

    Keys: press 'u' or '?' inside the app for the full keybinding reference.
  USAGE
end

def parse_args(argv)
  opts = { start: nil, resize: true, width: U::FORCED_WIDTH, height: U::FORCED_HEIGHT }
  i = 0
  while i < argv.length
    arg = argv[i]
    case arg
    when '--start'
      opts[:start] = argv[i + 1]
      i += 1
    when '--width'
      opts[:width] = argv[i + 1].to_i
      i += 1
    when '--height'
      opts[:height] = argv[i + 1].to_i
      i += 1
    when '--no-resize'
      opts[:resize] = false
    when '--help', '-h'
      print_usage
      exit 0
    else
      opts[:start] ||= arg unless arg.start_with?('--')
    end
    i += 1
  end
  opts
end

opts = parse_args(ARGV)

start = opts[:start] || Dir.home || ENV['HOME'] || Dir.pwd
start = File.expand_path(start)

unless File.exist?(start)
  warn "u: no such file or directory: #{start}"
  exit 1
end

width = opts[:width].to_i.positive? ? opts[:width] : U::FORCED_WIDTH
height = opts[:height].to_i.positive? ? opts[:height] : U::FORCED_HEIGHT

U.new(start, resize: opts[:resize], width: width, height: height).run
