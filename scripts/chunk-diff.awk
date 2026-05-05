# chunk-diff.awk — Split a unified diff into ~chunk_size-line chunks
# along file and hunk boundaries. Splits mid-hunk when a hunk exceeds chunk_size.
#
# Usage:
#   awk -v chunk_size=10000 -v output_dir=/tmp/chunks -f chunk-diff.awk < diff.txt
#
# Output:
#   output_dir/chunk_001.diff, chunk_002.diff, ...
#   output_dir/chunk_count.txt  (contains the number of chunks)

BEGIN {
    if (chunk_size == 0) chunk_size = 5000
    if (output_dir == "") output_dir = "/tmp/chunks"

    chunk_num = 1
    chunk_lines = 0
    file_header = ""
    in_hunk = 0
    hunk_buf = ""
    hunk_line_count = 0
    hunk_header = ""
    needs_hunk_header = 0
}

# Detect file boundary: "diff --git a/... b/..."
/^diff --git / {
    # Flush any pending hunk from previous file
    flush_hunk()

    # If adding this file header would push us over and we have content, rotate
    if (chunk_lines > 0 && chunk_lines >= chunk_size) {
        close_chunk()
    }

    # Start accumulating new file header
    file_header = $0 "\n"
    header_written = 0
    in_hunk = 0
    next
}

# Accumulate file header lines (index, ---, +++ that follow "diff --git")
# Only match when NOT inside a hunk — otherwise lines like "--- old text" in
# diff content would be incorrectly stolen from the hunk buffer.
/^index / || /^--- / || /^\+\+\+ / || /^old mode / || /^new mode / || /^new file mode / || /^deleted file mode / || /^similarity index / || /^rename from / || /^rename to / || /^Binary files / {
    if (!in_hunk && file_header != "") {
        file_header = file_header $0 "\n"
        next
    }
}

# Detect hunk boundary: "@@ ... @@"
/^@@ / {
    # Flush previous hunk first
    flush_hunk()

    # If we're over chunk_size, rotate before starting this hunk
    if (chunk_lines > 0 && chunk_lines >= chunk_size) {
        # We need to repeat the file header in the new chunk
        close_chunk()
        # The file_header is preserved, it will be re-emitted on next write
        needs_file_header = 1
    }

    # Start new hunk: the @@ line itself is in hunk_buf, so any pending
    # mid-hunk-split header re-emission is no longer needed.
    in_hunk = 1
    hunk_header = $0
    hunk_buf = $0 "\n"
    hunk_line_count = 1
    needs_hunk_header = 0
    next
}

# Regular diff content lines (inside a hunk)
{
    if (in_hunk) {
        hunk_buf = hunk_buf $0 "\n"
        hunk_line_count++

        # Mid-hunk splitting — only for truly oversized hunks.
        # chunk_size is a guideline for file/hunk boundary splits (handled above).
        # Within a hunk, we're generous: prefer one 8K chunk over two 5K + 3K
        # when the content is logically connected.
        #   soft limit (1.2x): start looking for context lines to split at
        #   hard limit (1.5x): force-split regardless
        total = chunk_lines + hunk_line_count
        if (total >= chunk_size * 1.2) {
            is_context_line = (substr($0, 1, 1) == " " || $0 == "")
            if (is_context_line || total >= chunk_size * 1.5) {
                flush_hunk()
                close_chunk()
                # Still mid-hunk in the *new* chunk: the next chunk file must
                # begin with the @@ hunk header so the LLM has line context.
                # Re-enter "in_hunk" and arm header re-emission for the next
                # accumulation.
                in_hunk = 1
                hunk_buf = ""
                hunk_line_count = 0
                needs_hunk_header = 1
            }
        }
    } else if (file_header != "") {
        # Lines between file header and first hunk (shouldn't happen in valid diffs)
        file_header = file_header $0 "\n"
    }
}

function flush_hunk() {
    if (hunk_buf == "") return

    # Ensure file header is written before hunk content
    ensure_file_header()

    # If we landed in a fresh chunk while still inside a logical hunk, the
    # buffer for this chunk has not yet had a @@ header emitted. Re-emit the
    # saved hunk_header so the LLM sees correct line numbers.
    if (needs_hunk_header && hunk_header != "") {
        printf "%s\n", hunk_header >> chunk_file()
        chunk_lines += 1
        needs_hunk_header = 0
    }

    printf "%s", hunk_buf >> chunk_file()
    chunk_lines += hunk_line_count

    hunk_buf = ""
    hunk_line_count = 0
    in_hunk = 0
}

function ensure_file_header() {
    if (file_header == "") return

    # If this is the first content in the chunk, or we need to repeat after rotation
    if (needs_file_header || !header_written) {
        printf "%s", file_header >> chunk_file()
        # Count file header lines
        n = split(file_header, _fh_lines, "\n")
        chunk_lines += (n - 1)  # split adds empty element after trailing \n
        header_written = 1
        needs_file_header = 0
    }
}

function chunk_file() {
    return output_dir "/chunk_" sprintf("%03d", chunk_num) ".diff"
}

function close_chunk() {
    close(chunk_file())
    chunk_num++
    chunk_lines = 0
    header_written = 0
    needs_file_header = 1
    # needs_hunk_header is set by callers that close mid-hunk; do not blanket
    # clear here because the mid-hunk-split path needs it to remain true.
}

END {
    # Flush any remaining hunk
    flush_hunk()

    # If we had a file header but no hunks (e.g., binary file), write it
    if (file_header != "" && !header_written && needs_file_header) {
        ensure_file_header()
    }

    # Close last chunk
    if (chunk_lines > 0) {
        close(chunk_file())
    }

    # Write chunk count
    count_file = output_dir "/chunk_count.txt"
    print chunk_num > count_file
    close(count_file)
}
