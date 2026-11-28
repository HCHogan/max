# A search goes without a key first, then by each key in turn

`web_search` asks Exa's endpoint that takes no key while it answers, then
Exa's search API with each configured key in order. A source that says it
is used up is left out until it may have more. The design is in
[Web search](../design/tools.md#web-search).

## Context

- Max makes 200 to 250 searches a day, two chats two thirds of them. At
  Exa's price for the kind of search Max asks for, that is about 45
  dollars a month.
- Exa answers searches in two ways. Its search API takes a key and bills
  the key's account; an account gets some credit free each month, about
  a week of Max's searches. Its MCP server, the one it hosts for
  assistants, searches without a key: so many a second and a day from one
  address, and Exa doesn't publish how many. Its code allows two a second
  and fifty a day unless set otherwise.
- With one key, a key out of credit is every search failing until someone
  notices: Exa answers 402, and Max tells the chat it has no network.

## Decision

- **Sources in an order**: the endpoint without a key (`free`, on unless
  turned off), then the keys of `api_key_file`, one a line, as the file
  has them. A search goes to the first that isn't left out.
- **A source that fails passes the search on**, whatever the failure but
  a query Exa refuses, which no source would take.
- **A source that says it is used up is left out**: the endpoint without
  a key for as long as its `Retry-After` says, a second for its rate and
  up to a day for its day's count; a key Exa answers 402, 401 or 403 for
  an hour; a key asked too fast for as long as it says. max keeps this in
  memory and learns it again after a restart, at a search a source.
- **One search at a time without a key**, the rest waiting for it rather
  than spending a key: one answers in half a second, which keeps under
  the two a second.
- **What the endpoint without a key says is read as text**: its results
  come as lines, `Title:`, `URL:`, `Published:`, `Author:` and the
  excerpts, not as data.

## Why

- The searches that cost nothing are taken first, and a key is spent only
  on what is left over.
- Several keys mean one out of credit is not an outage: the next takes
  over within the same search, and the log says which is out.
- An hour for a spent key costs one refused request an hour, and finds
  the credit again within the hour it comes back, without anybody
  telling max.

## Cost

- The endpoint without a key is Exa's to change: its limits, its text and
  whether it stays free. If its text changes shape a search finds no
  results there and no error either; a failure it does report passes on
  to the keys.
- Its count is by address, and tank's address out is shared with what
  else leaves that way.
- A batch of four searches without a key takes two seconds, not half of
  one.
- Results differ a little by source: the endpoint without a key picks its
  own excerpts.

## Alternatives

- **Keys only, in order.** No text to read and no unpublished limit, but
  it gives up the searches that are free every day.
- **A file a key** (`api_key_files`). The list would be the
  configuration's, where an order is plainer; but adding a key would be
  two changes, the secret and the list, and the one file there is now
  would have to be renamed. One file of lines takes a key as a line.
- **Waiting out the rate's second** rather than spending a key on a
  search that came too fast. It would need a wait in the tool, which has
  none (see [Timeouts](../design/lifetimes.md#timeouts)); one search at a
  time comes to the same.
