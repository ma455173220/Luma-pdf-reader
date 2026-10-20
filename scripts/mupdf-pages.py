"""Reports how MuPDF reads each given PDF, page by page, as JSON on stdout.

Used by `luma-corpus-check --pages` as a third, independent reader when checking page edits
(turning, removing, reordering, inserting). For every file: whether MuPDF had to repair it, its
warnings, its outline (level, title, page), and per page the text fingerprint (as read, and with
the characters sorted, which does not depend on reading order), size, rotation, annotations,
links (with the page they lead to) and form controls.
With `--without-output-intents <in.pdf> <out.pdf>` it writes a copy without the document's colour
profile for output (/OutputIntents), which pages inserted elsewhere leave behind.
With `--turn <in.pdf> <out.pdf> <page> <degrees>` it instead writes a copy of the file with one page
(counted from 0) given that turn, by MuPDF's own writer: an independent way to turn a page, for telling
how poppler reads a turned page from what the page writer did.
Run with `python3 -I` so nothing next to the PDFs can be imported.
"""
import hashlib
import json
import sys

import pymupdf


def fingerprint(text):
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()


if len(sys.argv) == 4 and sys.argv[1] == "--without-output-intents":
    # A copy without the document's colour profile for output, which inserted pages leave behind.
    copy = pymupdf.open(sys.argv[2])
    copy.xref_set_key(copy.pdf_catalog(), "OutputIntents", "null")
    copy.save(sys.argv[3])
    sys.exit(0)

if len(sys.argv) == 6 and sys.argv[1] == "--turn":
    turned = pymupdf.open(sys.argv[2])
    turned[int(sys.argv[4])].set_rotation(int(sys.argv[5]))
    turned.save(sys.argv[3])
    sys.exit(0)

results = []
for path in sys.argv[1:]:
    pymupdf.TOOLS.reset_mupdf_warnings()
    try:
        document = pymupdf.open(path)
        pages = []
        for page in document:
            annotations = []
            for annotation in page.annots() or []:
                annotations.append([
                    annotation.type[1],
                    [round(value, 1) for value in annotation.rect],
                    annotation.info.get("content", ""),
                ])
            links = []
            for link in page.get_links():
                if link.get("uri") is not None:
                    target = "uri:" + str(link["uri"])
                elif link.get("kind") in (pymupdf.LINK_GOTO, pymupdf.LINK_NAMED) and link.get("page") is not None:
                    # A named destination is given with the page it resolves to.
                    target = "page:" + str(link.get("page"))
                else:
                    target = "kind:" + str(link.get("kind"))
                links.append([[round(value, 1) for value in link["from"]], target])
            controls = [
                [str(widget.field_type_string), [round(value, 1) for value in widget.rect],
                 str(widget.field_name) + "=" + str(widget.field_value)]
                for widget in page.widgets() or []
            ]
            text = page.get_text()
            # A page tied into the document's structure information: MuPDF's reading order uses it.
            structured = document.xref_get_key(page.xref, "StructParents")[0] != "null"
            pages.append({
                "structured": structured,
                "text": fingerprint(text),
                "chars": fingerprint("".join(sorted(ch for ch in text if not ch.isspace()))),
                "box": [round(value, 2) for value in page.rect],
                "mediabox": [round(value, 2) for value in page.mediabox],
                "rotation": page.rotation,
                "annotations": annotations,
                "links": links,
                "controls": controls,
            })
        toc = [[level, title, page] for level, title, page in document.get_toc(simple=True)]
        results.append({
            "ok": True,
            "outputIntents": document.xref_get_key(document.pdf_catalog(), "OutputIntents")[0] != "null",
            "repaired": bool(document.is_repaired),
            "warnings": pymupdf.TOOLS.mupdf_warnings(),
            "pages": pages,
            "toc": toc,
        })
    except Exception as error:  # report, never crash: the caller compares before and after
        results.append({"ok": False, "error": str(error)})
print(json.dumps(results))
