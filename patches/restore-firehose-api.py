#!/usr/bin/env python3
"""Adapt libdispatch's kernel Firehose implementation to XNU's QEMU API."""
from pathlib import Path

replacements = {
    Path("libkern/firehose/firehose_buffer.c"): (
        """void
__firehose_merge_updates(firehose_push_reply_t update)
{
\tfirehose_buffer_t fb = kernel_firehose_buffer;
\tif (likely(fb)) {
\t\tfirehose_client_merge_updates(fb, true, update, false, NULL);
\t}
}""",
        """bool
__firehose_merge_updates(firehose_push_reply_t update)
{
\tfirehose_buffer_t fb = kernel_firehose_buffer;
\tif (unlikely(!fb)) {
\t\treturn false;
\t}
\tfirehose_client_merge_updates(fb, true, update, false, NULL);
\treturn true;
}""",
    ),
    Path("libkern/os/firehose_buffer_private.h"): (
        "void\n__firehose_merge_updates(firehose_push_reply_t update);",
        "bool\n__firehose_merge_updates(firehose_push_reply_t update);",
    ),
    Path("EXTERNAL_HEADERS/os/firehose_buffer_private.h"): (
        "void\n__firehose_merge_updates(firehose_push_reply_t update);",
        "bool\n__firehose_merge_updates(firehose_push_reply_t update);",
    ),
}

source = Path("libkern/firehose/firehose_buffer.c")
text = source.read_text()
for header in ("internal/atomic.h", "firehose_types_private.h", "tracepoint_private.h", "chunk_private.h"):
    text = text.replace(f"<{header}>", f'"{header}"')
source.write_text(text)

for path, (old, new) in replacements.items():
    text = path.read_text()
    if text.count(old) != 1:
        raise SystemExit(f"expected one Firehose API occurrence in {path}")
    path.write_text(text.replace(old, new))
