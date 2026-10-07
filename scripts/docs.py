"""Local HarmonyOS docs search tool backed by deveco-cli's docs.zip/index.zip.

Usage:
  python scripts/docs.py search <keywords...> [--limit N]
  python scripts/docs.py read <document_id> [section_title]
"""
import sqlite3
import sys
import zipfile
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(ROOT, ".docs", "search.db")
DOCS_ZIP = os.path.join(ROOT, "node_modules", "@deveco", "deveco-cli", "docs.zip")


def fix_name(info):
    """docs.zip stores UTF-8 names without the UTF-8 flag; zipfile decodes as cp437."""
    name = info.filename
    try:
        name = name.encode("cp437").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        pass
    return name


def open_docs():
    """Yield (fixed_name, ZipInfo) pairs."""
    with zipfile.ZipFile(DOCS_ZIP) as f:
        for info in f.infolist():
            yield fix_name(info), info


def search(keywords, limit=10):
    con = sqlite3.connect(DB)
    q = " OR ".join(f'"{k}"' for k in keywords)
    rows = con.execute(
        """
        SELECT d.document_id, d.doc_title, MAX(s.lead_text),
               SUM(COALESCE(s.excerpt_truncated, 0)) AS hits
        FROM segments_fts ft
        JOIN segments s ON s.id = ft.rowid
        JOIN documents d ON d.id = s.doc_id
        WHERE segments_fts MATCH ?
        GROUP BY d.id
        ORDER BY hits DESC, d.id
        LIMIT ?
        """,
        (q, limit),
    ).fetchall()
    for doc_id, title, lead, hits in rows:
        lead = (lead or "").replace("\n", " ")[:80]
        print(f"{doc_id}  [{title}]  ({hits} hits)\n    {lead}")


def read(doc_id):
    """Print the markdown body of a document, matched by fixed name."""
    target = doc_id.replace("/", "\\") if "\\" not in doc_id else doc_id
    with zipfile.ZipFile(DOCS_ZIP) as f:
        for info in f.infolist():
            if fix_name(info).replace("/", "\\").endswith(target + ".md") or \
               fix_name(info) == doc_id + ".md":
                data = f.read(info)
                sys.stdout.buffer.write(data)
                return
    print(f"document not found: {doc_id}", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    cmd = sys.argv[1]
    args = sys.argv[2:]
    if cmd == "search":
        limit = 10
        if "--limit" in args:
            i = args.index("--limit")
            limit = int(args[i + 1])
            del args[i:i + 2]
        search(args, limit)
    elif cmd == "read":
        read(args[0])
    else:
        print(__doc__)
        sys.exit(1)
