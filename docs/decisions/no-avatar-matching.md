# No matching people by avatar

People from a group's earlier records are not joined to their accounts
automatically, neither by a command nor by comparing avatars.

## Context

The official API gives only openids, a different one per group, while the
records imported from before the official bot name people by QQ number.
Unless something joins an old member to their account, they count as a
new person.

Avatars are the one thing both sides have. The official bot fetches one
by openid (`q.qlogo.cn/qqapp/<AppID>/<openid>/640`), and a public
endpoint gives one by number (`q1.qlogo.cn/g?b=qq&nk=<number>&s=640`).
Scaled to 16×16 greyscale, two pictures of one person differ by 0.03% in
root-mean-square, different people's by 36 to 60%. Accounts without an
avatar, and openids that don't exist, all return one default picture.

## Decision

No automatic linking. People from old groups are new people in the new
groups. Linking one is done by hand, by editing `principals.merged_into`
in the database; users' own claims aren't trusted.

## Why

Anyone can change their avatar, and avatars are public. A match by avatar
is a claim anyone can make for anyone:

- **A command that links the sender to an old number**, checked by
  avatar: within a day of having one, someone switched to another
  person's avatar and was linked as them.
- **Matching by itself**, in groups that continue an old one: each
  account's avatar compared with those of the old numbers that spoke
  there, merged when exactly one matches and no other account competes
  for that number, with accounts that resemble an owner's or Max's old
  number left unlinked and logged. It linked 134 accounts in a week. The
  risk stays: one who switches to an absent old member's avatar is linked
  as them, and a log is the only safeguard.

## Cost

A member's years of earlier messages aren't theirs to Max until someone
links them by hand.
