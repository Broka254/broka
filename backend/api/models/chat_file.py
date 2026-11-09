"""Documents shared in a direct chat (2026-11-09): a PDF, a Word or Excel
file, a text file - what buyers and sellers swap as invoices, receipts,
logbooks and specifications.

A chat photo is stored inline in its message (`negotiation_messages.
media_url`, a data URI). A document is not: it can be many times the size
of a photo, and every history request and every chat socket replays the
thread's rows - a 10 MB file inline would be resent on each of them. The
message carries `media_url = "/media/chat-files/<id>"` and the file's
name, size and type; the bytes are here, and only the two people in the
thread can fetch them (GET /media/chat-files/{id}, api/routers/media.py).

Never in the public media bucket: a document is someone's paperwork, and
R2's public URLs (api/core/media_storage.py) are readable by anyone who
learns one. Unsending the message deletes the row.

A new table, so init_db()'s create_all() creates it (schema revision 13).
"""
from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import Column, DateTime, Integer, LargeBinary, String

from api.database import Base


class ChatFile(Base):
    __tablename__ = "chat_files"

    id          = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    # Who sent it, and the thread it was sent into: (listing_id or store_id,
    # buyer_id) - the same identity as the message's. Plain ids rather than
    # foreign keys, like the message's own sender_id and buyer_id.
    uploader_id = Column(String, nullable=False, index=True)
    listing_id  = Column(String, nullable=True, index=True)
    store_id    = Column(String, nullable=True, index=True)
    buyer_id    = Column(String, nullable=False)
    # As shown in the chat: cleaned of any path and of control characters.
    file_name   = Column(String(255), nullable=False)
    # Decided by the server from the file's extension and its first bytes,
    # never taken from the uploading client.
    mime_type   = Column(String(127), nullable=False)
    size_bytes  = Column(Integer, nullable=False)
    sha256      = Column(String(64), nullable=False)
    data        = Column(LargeBinary, nullable=False)
    created_at  = Column(DateTime, default=datetime.utcnow, nullable=False)
