"""Reports how MuPDF reads each given PDF, as JSON on stdout.

Used by luma-corpus-check as a third, independent reader. For every file: whether MuPDF had
to repair it, its warnings, and per page the text fingerprint, size, rotation, annotations,
links and form controls.
Run with `python3 -I` so nothing next to the PDFs can be imported.
"""
import hashlib
import json
import sys

import pymupdf

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
            # Links and form controls are annotations too, but MuPDF lists them separately.
            links = [
                # Page numbers start at 0, so "or" must not be used to pick between the address and the page.
                [str(link.get("kind")), [round(value, 1) for value in link["from"]],
                 "uri:" + str(link["uri"]) if link.get("uri") is not None else "page:" + str(link.get("page"))]
                for link in page.get_links()
            ]
            controls = [
                [str(widget.field_type_string), [round(value, 1) for value in widget.rect],
                 str(widget.field_name) + "=" + str(widget.field_value)]
                for widget in page.widgets() or []
            ]
            pages.append({
                "text": hashlib.sha256(page.get_text().encode("utf-8", "replace")).hexdigest(),
                "box": [round(value, 2) for value in page.rect],
                "rotation": page.rotation,
                "annotations": annotations,
                "links": links,
                "controls": controls,
            })
        results.append({
            "ok": True,
            "repaired": bool(document.is_repaired),
            "warnings": pymupdf.TOOLS.mupdf_warnings(),
            "pages": pages,
        })
    except Exception as error:  # report, never crash: the caller compares before and after
        results.append({"ok": False, "error": str(error)})
print(json.dumps(results))
