-- context_read reads a conversation from a moment on: its first row then.

create index on messages (conversation_id, sent_at);
