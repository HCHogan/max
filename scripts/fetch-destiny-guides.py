#!/usr/bin/env python3
"""Download the four Destiny guide workbooks as one CSV per worksheet.

Requires openpyxl and beautifulsoup4. Uses public XLSX exports where available,
otherwise reads the publicly rendered HTML worksheets. No sandbox is involved.
Writes raw spreadsheet grids, an index, and metadata sidecars; it does not
normalize recommendations or implement the bot's guide tools.
"""

import argparse
import csv
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
import warnings
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timezone
from pathlib import Path
from urllib.parse import urljoin
from zipfile import ZipFile
import xml.etree.ElementTree as ET

from bs4 import BeautifulSoup
from openpyxl import load_workbook
from openpyxl.utils import get_column_letter


ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    ("court", "Destiny 2 Damage Buffs/Debuffs - JUNE UPDATE", "1i1KUwgVkd8qhwYj481gkV9sZNJQCE-C3Q-dpQutPCi4"),
    ("compendium", "Destiny Data Compendium", "1WaxvbLx7UoSZaBqdFr1u32F2uWVLo-CJunJB4nlGUE4"),
    ("endgame-analysis", "Destiny 2: Endgame Analysis", "1JM-0SlxVDAi-C6rGVlLxa-J1WGewEeL8Qvq4htWZHhY"),
    ("boss-damage", "Destiny 2: Boss Damage", "1_5wtBjRYHHxuF4oJKDb_iOGZs-wTkzB6RYbnyNLbuz4"),
]
NS = {"s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}


def stamp():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def download(url, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        ["curl", "--location", "--fail", "--silent", "--show-error", "--max-time", "90",
         "--retry", "2", "--retry-delay", "1", url, "--output", str(path)],
        capture_output=True, text=True, check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return path.read_bytes()


def discover(html):
    """Extract the public tab inventory, including hidden tabs when exposed."""
    match = re.search(r"bootstrapData\s*=\s*(\{.*?\});\s*function loadWaffle", html, re.S)
    if match:
        snapshot = json.loads(match[1])
        tabs = []
        for operation, payload in snapshot["changes"]["topsnapshot"]:
            if operation != 21350203:
                continue
            values = json.loads(payload)
            properties = values[3][0]["1"]
            hidden = any(isinstance(p, dict) and p.get("9") == 1 for p in properties)
            tabs.append({"gid": str(values[2]), "title": properties[0][2],
                         "visibility": "hidden" if hidden else "visible",
                         "grid_rows": values[4], "grid_columns": values[5]})
        if tabs:
            return tabs
    tabs = [{"title": name, "gid": gid, "visibility": "unknown"}
            for name, gid in re.findall(r'items\.push\(\{name: "([^"]*)"[^}]*gid: "(\d+)"', html)]
    if not tabs:
        raise ValueError("No worksheet inventory in the public document")
    return tabs


def text_value(value):
    if value is None:
        return ""
    if isinstance(value, datetime):
        return value.date().isoformat() if value.time().isoformat() == "00:00:00" else value.isoformat()
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    return str(value)


def html_grid(raw, gid, source_url):
    soup = BeautifulSoup(raw, "html.parser")
    table = soup.find("table", class_="waffle")
    if table is None:
        raise ValueError(f"No worksheet table: {source_url}")
    rendered = []
    for tr in table.select("tbody > tr"):
        header = tr.find("th", recursive=False)
        match = re.fullmatch(re.escape(gid) + r"R(\d+)", header.get("id", "")) if header else None
        if match:
            rendered.append((int(match[1]) + 1, tr))
    if not rendered:
        raise ValueError(f"No numbered worksheet rows: {source_url}")
    grid, occupied = {}, set()
    metadata = {"merged_ranges": [], "hyperlinks": {}, "images": {}, "rich_text": {},
                "cell_notes": {}, "rendered_rows": [row for row, _ in rendered]}
    columns = len(table.select("thead th[id]"))
    for position, (row, tr) in enumerate(rendered):
        col = 1
        for td in tr.find_all("td", recursive=False):
            while (row, col) in occupied:
                col += 1
            colspan, rowspan = int(td.get("colspan", 1)), int(td.get("rowspan", 1))
            covered = rendered[position:position + rowspan]
            for next_row, _ in covered:
                for next_col in range(col, col + colspan):
                    occupied.add((next_row, next_col))
            ref = f"{get_column_letter(col)}{row}"
            if colspan > 1 or rowspan > 1:
                end_row = covered[-1][0]
                metadata["merged_ranges"].append(f"{ref}:{get_column_letter(col + colspan - 1)}{end_row}")
            links = [{"text": a.get_text(), "url": urljoin(source_url, a["href"])}
                     for a in td.find_all("a", href=True)]
            if links:
                metadata["hyperlinks"][ref] = links
            images = [{"url": image["src"], "alt": image.get("alt", "")}
                      for image in td.find_all("img", src=True)]
            if images:
                metadata["images"][ref] = images
            runs = [{"text": span.get_text(), "style": span["style"]}
                    for span in td.find_all("span", style=True) if span.get_text()]
            if runs:
                metadata["rich_text"][ref] = runs
            for br in td.find_all("br"):
                br.replace_with("\n")
            grid[row, col] = td.get_text()
            columns = max(columns, col + colspan - 1)
            col += colspan
    rows = [[grid.get((r, c), "") for c in range(1, columns + 1)]
            for r in range(1, rendered[-1][0] + 1)]
    metadata["notes_availability"] = "Public HTML does not expose all spreadsheet cell notes or formulas."
    return rows, metadata


def xlsx_metadata(archive, number):
    path = f"xl/worksheets/sheet{number}.xml"
    root = ET.fromstring(archive.read(path))
    metadata = {"merged_ranges": [node.attrib["ref"] for node in root.findall("s:mergeCells/s:mergeCell", NS)],
                "hyperlinks": {}, "cell_notes": {}, "formulas": {}, "rich_text": {},
                "hidden_rows": [int(node.attrib["r"]) for node in root.findall("s:sheetData/s:row", NS)
                                if node.get("hidden") == "1"]}
    relpath = f"xl/worksheets/_rels/sheet{number}.xml.rels"
    rels = {}
    if relpath in archive.namelist():
        for node in ET.fromstring(archive.read(relpath)):
            rels[node.attrib["Id"]] = node.attrib["Target"]
    for node in root.findall("s:hyperlinks/s:hyperlink", NS):
        rid = node.get("{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id")
        metadata["hyperlinks"][node.attrib["ref"]] = rels.get(rid, node.get("location", ""))
    for cell in root.findall("s:sheetData/s:row/s:c", NS):
        formula = cell.find("s:f", NS)
        if formula is not None:
            metadata["formulas"][cell.attrib["r"]] = formula.text or ""
    for target in rels.values():
        if "comments" not in target.lower() or not target.endswith(".xml"):
            continue
        import posixpath
        target = target.lstrip("/") if target.startswith("/") else posixpath.normpath(posixpath.join("xl/worksheets", target))
        if target not in archive.namelist():
            continue
        for comment in ET.fromstring(archive.read(target)).findall("s:commentList/s:comment", NS):
            metadata["cell_notes"][comment.attrib["ref"]] = "".join(comment.itertext())
    metadata["drawings_present"] = root.find("s:drawing", NS) is not None
    return metadata


def write_sheet(stage, source_id, tab, rows, metadata, retrieval):
    # Trim only trailing empty rows; source row numbers remain CSV record numbers.
    while rows and not any(rows[-1]):
        rows.pop()
    columns = max((len(row) for row in rows), default=0)
    slug = re.sub(r"[^a-z0-9]+", "-", tab["title"].lower()).strip("-")
    relative = Path(source_id) / f"{slug}--{tab['gid']}.csv"
    path = stage / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerows(row + [""] * (columns - len(row)) for row in rows)
    sidecar = relative.with_suffix(".metadata.json")
    (stage / sidecar).write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    vocabulary = {"name", "type", "family", "notes", "description", "perk", "perk 1", "perk 2", "icon",
                  "armor", "effect", "trigger", "tier", "source", "frame", "bonus", "pcs", "date",
                  "tab", "updated", "status", "activity", "boss", "total", "dps", "energy", "season"}
    headers = [{"row": number, "cells": {get_column_letter(col): value for col, value in enumerate(row, 1) if value}}
               for number, row in enumerate(rows, 1)
               if sum(value.strip().lower() in vocabulary for value in row) >= 2][:12]
    title = tab["title"].lower()
    status = "ignore" if "ignore" in title else "historical" if re.search(r"\bold\b|outdated|not updated|historical", title) else "unspecified"
    data = path.read_bytes()
    return {**tab, "id": f"{source_id}/{tab['gid']}", "path": relative.as_posix(),
            "metadata_path": sidecar.as_posix(), "source_url": retrieval["source_url"],
            "retrieval_method": retrieval["method"], "fetched_at": retrieval["fetched_at"],
            "source_status": status, "rows": len(rows), "columns": columns,
            "nonempty_cells": sum(bool(value) for row in rows for value in row),
            "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "schema": {"layout": "raw_spreadsheet_grid", "column_ids": [get_column_letter(c) for c in range(1, columns + 1)],
                       "header_rows": headers},
            "preview": [{"row": number, "cells": {get_column_letter(col): value[:240] for col, value in enumerate(row, 1) if value}}
                        for number, row in enumerate(rows[:5], 1) if any(row)]}


def fetch_source(source, cache, stage):
    source_id, title, spreadsheet_id = source
    base = f"https://docs.google.com/spreadsheets/d/{spreadsheet_id}"
    html = download(base + "/edit", cache / source_id / "catalog.html").decode("utf-8")
    tabs = discover(html)
    workbook_path = cache / source_id / "workbook.xlsx"
    export_error = None
    try:
        download(base + "/export?format=xlsx", workbook_path)
        method = "xlsx_cached_values"
    except RuntimeError as error:
        export_error = str(error)
        method = "public_html"
    source_stamp = stamp()
    records = []
    if method == "xlsx_cached_values":
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            workbook = load_workbook(workbook_path, read_only=True, data_only=True)
        by_name = {tab["title"]: tab for tab in tabs}
        if set(by_name) != set(workbook.sheetnames):
            raise ValueError(f"Worksheet inventory differs from XLSX: {source_id}")
        with ZipFile(workbook_path) as archive:
            for number, sheet in enumerate(workbook, 1):
                tab = {**by_name[sheet.title], "visibility": sheet.sheet_state}
                rows = [[text_value(value) for value in row] for row in sheet.iter_rows(values_only=True)]
                metadata = xlsx_metadata(archive, number)
                records.append(write_sheet(stage, source_id, tab, rows, metadata,
                    {"source_url": base + f"/edit?gid={tab['gid']}", "method": method, "fetched_at": source_stamp}))
        workbook.close()
    else:
        def fetch_tab(tab):
            url = base + f"/htmlview/sheet?headers=true&gid={tab['gid']}"
            raw = download(url, cache / source_id / f"{tab['gid']}.html")
            rows, metadata = html_grid(raw, tab["gid"], base + f"/edit?gid={tab['gid']}")
            return write_sheet(stage, source_id, tab, rows, metadata,
                {"source_url": base + f"/edit?gid={tab['gid']}", "method": method, "fetched_at": stamp()})
        with ThreadPoolExecutor(max_workers=4) as pool:
            records = list(pool.map(fetch_tab, tabs))
    print(f"{source_id}: {len(records)} CSVs, {sum(record['rows'] for record in records)} rows ({method})", flush=True)
    return {"id": source_id, "title": title, "spreadsheet_id": spreadsheet_id, "source_url": base + "/edit",
            "fetched_at": source_stamp, "retrieval_method": method, "direct_export_error": export_error, "sheets": records}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "data/destiny-guides")
    parser.add_argument("--cache", type=Path, default=ROOT / "var/destiny-guides-import")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="max-destiny-guides-") as directory:
        stage = Path(directory)
        # Sources are sequential; only independent public worksheet downloads run in parallel.
        sources = [fetch_source(source, args.cache, stage) for source in SOURCES]
        index = {"format_version": 1, "generated_at": stamp(), "encoding": "utf-8", "csv_delimiter": ",",
                 "row_numbering": "CSV record 1 is spreadsheet row 1; there is no synthetic header. Parse CSV records, not physical lines.",
                 "cell_values": "Displayed HTML text or cached XLSX values; formulas and available notes are in sidecars. Images are not CSV cell text.",
                 "sources": sources}
        (stage / "index.json").write_text(json.dumps(index, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        # Complete all downloads and parsing before replacing any checked-in data.
        args.output.mkdir(parents=True, exist_ok=True)
        shutil.copytree(stage, args.output, dirs_exist_ok=True)
        print(f"Wrote {sum(len(source['sheets']) for source in sources)} CSVs to {args.output}")


if __name__ == "__main__":
    main()
