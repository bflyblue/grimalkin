package main

// Detection is deliberately a pure function of the snapshot. Only viewport
// rows exist there, so an address whose scheme has scrolled off the top does
// not match; opening nothing is safer than opening a truncated address.

import "core:strings"

URL_TEXT_MAX_BYTES :: 2048

// Viewport-relative cell coordinate. Rows are snapshot rows, not absolute
// scrollback rows, so a match is only valid for the snapshot it came from.
Url_Cell :: struct {
	row: u16,
	col: u16,
}

Url_Match :: struct {
	text:  string,
	cells: []Url_Cell,
}

// Only these schemes are ever detected, and the same allowlist is enforced
// again at the point of opening. Any program can print any text to a terminal,
// so a widened detector must never widen what a click can launch.
url_schemes := [?]string{"https://", "http://", "mailto:"}

url_is_scheme_byte :: proc(value: u8) -> bool {
	switch value {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '+', '-', '.':
		return true
	}
	return false
}

// RFC 3986 unreserved and reserved characters plus the percent sign. Trailing
// punctuation that is also valid here is trimmed afterwards.
url_is_body_byte :: proc(value: u8) -> bool {
	switch value {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9':
		return true
	case '-', '.', '_', '~', ':', '/', '?', '#', '[', ']', '@':
		return true
	case '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', '%':
		return true
	}
	return false
}

url_ascii_lower :: proc(value: u8) -> u8 {
	return value + 32 if value >= 'A' && value <= 'Z' else value
}

url_scheme_length_at :: proc(line: []u8, position: int) -> (length: int, ok: bool) {
	for scheme in url_schemes {
		if position + len(scheme) > len(line) do continue
		matched := true
		for index in 0 ..< len(scheme) {
			if url_ascii_lower(line[position + index]) != scheme[index] {
				matched = false
				break
			}
		}
		if matched do return len(scheme), true
	}
	return 0, false
}

url_brackets_balanced :: proc(span: []u8, open, close: u8) -> bool {
	depth := 0
	for value in span {
		if value == open {
			depth += 1
		} else if value == close {
			depth -= 1
		}
	}
	return depth >= 0
}

// Sentence punctuation is valid inside a URL but almost never ends one, and a
// closing bracket only belongs to the URL when the URL opened it.
url_trimmed_length :: proc(span: []u8) -> int {
	length := len(span)
	for length > 0 {
		last := span[length - 1]
		if last == '.' || last == ',' || last == ';' || last == ':' ||
		   last == '!' || last == '?' || last == '\'' || last == '"' ||
		   last == '*' || last == '_' || last == '~' {
			length -= 1
			continue
		}
		if last == ')' && !url_brackets_balanced(span[:length], '(', ')') {
			length -= 1
			continue
		}
		if last == ']' && !url_brackets_balanced(span[:length], '[', ']') {
			length -= 1
			continue
		}
		break
	}
	return length
}

// Kept separate from the snapshot walk so matching policy is directly testable.
url_span_in_line :: proc(line: []u8, index: int) -> (start, end: int, ok: bool) {
	position := 0
	for position < len(line) {
		scheme_length, is_scheme := url_scheme_length_at(line, position)
		// A scheme byte in front means this is the tail of a longer word,
		// as in "xhttp://"; a bracket or space in front is a real boundary.
		if !is_scheme || (position > 0 && url_is_scheme_byte(line[position - 1])) {
			position += 1
			continue
		}
		body_end := position + scheme_length
		for body_end < len(line) && url_is_body_byte(line[body_end]) do body_end += 1
		trimmed := position + url_trimmed_length(line[position:body_end])
		if trimmed > position + scheme_length &&
		   trimmed - position <= URL_TEXT_MAX_BYTES &&
		   index >= position && index < trimmed {
			return position, trimmed, true
		}
		position = max(body_end, position + 1)
	}
	return 0, 0, false
}

url_logical_line_bounds :: proc(snapshot: ^Terminal_Snapshot, row: int) -> (first, last: int) {
	first = row
	last = row
	for first > 0 && snapshot.row_data[first].wrap_continuation do first -= 1
	for last + 1 < int(snapshot.rows) && snapshot.row_data[last].wrap do last += 1
	return
}

// Non-ASCII text and empty cells become spaces so they terminate a URL.
// Ghostty's wide-character spacers are skipped so one wide glyph contributes
// one candidate byte while the parallel coordinates retain its cell position.
url_flatten_logical_line :: proc(
	snapshot: ^Terminal_Snapshot,
	row: int,
	allocator := context.allocator,
) -> (line: []u8, cells: []Url_Cell) {
	first, last := url_logical_line_bounds(snapshot, row)
	bytes := make([dynamic]u8, 0, int(snapshot.cols) * (last - first + 1), allocator)
	coordinates := make([dynamic]Url_Cell, 0, int(snapshot.cols) * (last - first + 1), allocator)
	for line_row := first; line_row <= last; line_row += 1 {
		row_offset := line_row * int(snapshot.cols)
		for column := 0; column < int(snapshot.cols); column += 1 {
			cell := &snapshot.cells[row_offset + column]
			if cell.wide == .Spacer_Tail || cell.wide == .Spacer_Head do continue
			coordinate := Url_Cell{row = u16(line_row), col = u16(column)}
			graphemes := terminal_cell_graphemes(snapshot, line_row, cell)
			if !cell.has_text || len(graphemes) == 0 {
				append(&bytes, ' ')
				append(&coordinates, coordinate)
				continue
			}
			for codepoint in graphemes {
				append(&bytes, u8(codepoint) if codepoint < 0x80 else ' ')
				append(&coordinates, coordinate)
			}
		}
	}
	return bytes[:], coordinates[:]
}

// The match owns its text and cells in `allocator`; scratch flattening uses the
// frame arena and is never retained.
url_find_at :: proc(
	snapshot: ^Terminal_Snapshot,
	row, column: int,
	allocator := context.allocator,
) -> (match: Url_Match, ok: bool) {
	if snapshot == nil || snapshot.cols == 0 || snapshot.rows == 0 do return {}, false
	if row < 0 || row >= int(snapshot.rows) || column < 0 || column >= int(snapshot.cols) {
		return {}, false
	}
	if len(snapshot.row_data) < int(snapshot.rows) do return {}, false

	line, coordinates := url_flatten_logical_line(snapshot, row, context.temp_allocator)
	if len(line) == 0 do return {}, false

	// A cell skipped during flattening (a wide spacer) has no byte of its own,
	// so fall back to the head cell that covers it.
	target := -1
	for coordinate, index in coordinates {
		if int(coordinate.row) == row && int(coordinate.col) <= column {
			if int(coordinate.col) == column {
				target = index
				break
			}
			target = index
		} else if int(coordinate.row) > row {
			break
		}
	}
	if target < 0 do return {}, false

	start, end, found := url_span_in_line(line, target)
	if !found do return {}, false

	match.text = strings.clone(string(line[start:end]), allocator)
	span_cells := make([dynamic]Url_Cell, 0, end - start, allocator)
	for index in start ..< end {
		coordinate := coordinates[index]
		if len(span_cells) > 0 && span_cells[len(span_cells) - 1] == coordinate do continue
		append(&span_cells, coordinate)
	}
	match.cells = span_cells[:]
	return match, true
}

url_match_destroy :: proc(match: ^Url_Match, allocator := context.allocator) {
	delete(match.text, allocator)
	delete(match.cells, allocator)
	match^ = {}
}

// The allowlist enforced at the point of opening. Detection already limits the
// schemes it recognises; this repeats the check at the boundary that launches a
// program so a future detector change cannot silently widen it.
url_is_openable :: proc(text: string) -> bool {
	if len(text) == 0 || len(text) > URL_TEXT_MAX_BYTES do return false
	for index in 0 ..< len(text) {
		// Control characters, spaces, and non-ASCII bytes never reach here from
		// detection, and must not reach a system opener from anywhere else.
		if text[index] <= 0x20 || text[index] >= 0x7f do return false
	}
	bytes := transmute([]u8)text
	scheme_length, ok := url_scheme_length_at(bytes, 0)
	return ok && len(text) > scheme_length
}
