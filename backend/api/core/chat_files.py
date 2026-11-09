"""Which documents a direct chat carries, and how they are named.

POST /media/upload takes documents (content_type "file") for the chat's
attachments: an invoice, a receipt, a logbook, a price list. A chat is a
channel between strangers, so what is accepted is a short list of
document types, each recognised from its first bytes as well as its name:

  * an executable or an archive renamed "price-list.pdf" is refused - the
    other side's phone would hand it to a PDF viewer, or worse, to
    whatever opens it;
  * the type the file is stored and served with is decided here, from the
    extension that matched its contents - never the uploading client's
    Content-Type, which is anything it says.

Downloads go out as attachments with nosniff (api/routers/media.py), so a
browser never renders one as a page either.
"""
from __future__ import annotations

import io
import unicodedata
import zipfile
from typing import Tuple

# Larger than a photo can be (10 MB): a scanned, multi-page PDF is the
# common case. Well under MAX_REQUEST_BODY_MB.
MAX_FILE_MB = 15
MAX_FILE_BYTES = MAX_FILE_MB * 1024 * 1024

# extension -> (MIME type, how its contents are recognised)
_DOCUMENT_TYPES = {
    "pdf":  ("application/pdf", "pdf"),
    "doc":  ("application/msword", "ole"),
    "xls":  ("application/vnd.ms-excel", "ole"),
    "ppt":  ("application/vnd.ms-powerpoint", "ole"),
    "docx": ("application/vnd.openxmlformats-officedocument.wordprocessingml.document", "ooxml"),
    "xlsx": ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "ooxml"),
    "pptx": ("application/vnd.openxmlformats-officedocument.presentationml.presentation", "ooxml"),
    "odt":  ("application/vnd.oasis.opendocument.text", "odf"),
    "ods":  ("application/vnd.oasis.opendocument.spreadsheet", "odf"),
    "odp":  ("application/vnd.oasis.opendocument.presentation", "odf"),
    "rtf":  ("application/rtf", "rtf"),
    "txt":  ("text/plain", "text"),
    "csv":  ("text/csv", "text"),
}

DOCUMENT_EXTENSIONS = frozenset(_DOCUMENT_TYPES)

_OLE_MAGIC = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"
_ZIP_MAGIC = b"PK\x03\x04"

# Characters a file name never needs and some file systems refuse.
_RESERVED = set('<>:"/\\|?*')

MAX_NAME_CHARS = 120


class FileRejected(ValueError):
    """The upload is not a document a chat may carry; the message says
    why, in words for the person who picked it."""


def clean_file_name(raw: str) -> str:
    """The name to show and save the file under: no folders (a name like
    "../../x" or "C:\\Users\\x" is just "x"), no control or reserved
    characters, at most MAX_NAME_CHARS with its extension kept."""
    name = (raw or "").replace("\\", "/").split("/")[-1]
    name = unicodedata.normalize("NFC", name)
    name = "".join(ch for ch in name
                   if ch not in _RESERVED and unicodedata.category(ch)[0] != "C")
    name = " ".join(name.split()).strip(" .")
    if not name:
        return "document"
    if len(name) > MAX_NAME_CHARS:
        stem, dot, ext = name.rpartition(".")
        if dot and 0 < len(ext) <= 8:
            name = stem[: MAX_NAME_CHARS - len(ext) - 1].rstrip(" .") + "." + ext
        else:
            name = name[:MAX_NAME_CHARS]
    return name


def extension_of(name: str) -> str:
    stem, dot, ext = name.rpartition(".")
    return ext.lower() if dot and stem else ""


def _zip_names(data: bytes) -> set:
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            # The central directory only: nothing is decompressed, so a
            # zip bomb costs no more than its own size.
            return set(archive.namelist())
    except (zipfile.BadZipFile, ValueError, OSError):
        return set()


def _is_text(data: bytes) -> bool:
    if b"\x00" in data:
        return False
    for encoding in ("utf-8", "cp1252"):
        try:
            data.decode(encoding)
            return True
        except UnicodeDecodeError:
            continue
    return False


def _contents_match(kind: str, data: bytes) -> bool:
    if kind == "pdf":
        # The header may follow a little junk; readers look in the first KB.
        return b"%PDF-" in data[:1024]
    if kind == "ole":
        return data.startswith(_OLE_MAGIC)
    if kind == "ooxml":
        return data.startswith(_ZIP_MAGIC) and "[Content_Types].xml" in _zip_names(data)
    if kind == "odf":
        return data.startswith(_ZIP_MAGIC) and "mimetype" in _zip_names(data)
    if kind == "rtf":
        return data.startswith(b"{\\rtf")
    if kind == "text":
        return _is_text(data)
    return False


def accept_document(file_name: str, data: bytes) -> Tuple[str, str]:
    """(the name to keep, the MIME type to store and serve it as) for a
    document a chat may carry. Raises FileRejected otherwise."""
    name = clean_file_name(file_name)
    ext = extension_of(name)
    if ext not in _DOCUMENT_TYPES:
        raise FileRejected(
            "This type of file can't be sent. Send a PDF, Word, Excel, "
            "PowerPoint, text or CSV file.")
    if not data:
        raise FileRejected("The file is empty.")
    if len(data) > MAX_FILE_BYTES:
        raise FileRejected(f"The file is too large (max {MAX_FILE_MB} MB).")
    mime, kind = _DOCUMENT_TYPES[ext]
    if not _contents_match(kind, data):
        raise FileRejected(f"This file isn't a real .{ext} file.")
    return name, mime


def content_disposition(file_name: str) -> str:
    """`attachment` with the name in both forms: an ASCII fallback for old
    clients and the exact name (RFC 6266 / 5987) for everyone else."""
    from urllib.parse import quote

    fallback = "".join(ch if 32 <= ord(ch) < 127 and ch not in '"\\' else "_" for ch in file_name)
    return f"attachment; filename=\"{fallback}\"; filename*=UTF-8''{quote(file_name, safe='')}"


def file_fields(message) -> dict:
    """A shared document's name, size and type as every message payload
    carries them - the socket, /history, the upload's own answer. Null on
    anything that isn't a document, and on one that was unsent."""
    is_file = ((getattr(message, "msg_type", None) or "") == "file"
               and getattr(message, "deleted_at", None) is None)
    return {
        "file_name": getattr(message, "file_name", None) if is_file else None,
        "file_size": getattr(message, "file_size", None) if is_file else None,
        "file_mime": getattr(message, "file_mime", None) if is_file else None,
    }
