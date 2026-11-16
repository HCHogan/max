# No matching people by avatar

People from the old groups are not joined to their new accounts
automatically, neither by a command nor by comparing avatars.

## Context

The official API gives only openids, a different one per group, while the
Haskell version's people are stored by QQ number. Something had to join an
old member to their new accounts, or they would count as new people.

## What was tried

- **`/link <QQ number>`**: verified by avatar, it linked the sender's
  account to an old number's person. Avatars are public, and within a day
  someone switched to another person's avatar and was linked as them. The
  command and the reminders urging people to link were removed, and its 18
  links cleared. (Today's `/link` is another command, which links
  conversations.)
- **Matching by avatar**, which ran for a week: in groups that
  continue an old group, maxx compared each account's avatar with those of
  the old numbers that had spoken there, and merged it when exactly one
  matched and no other account competed for that number.
  - The official bot fetches an avatar by openid
    (`q.qlogo.cn/qqapp/<AppID>/<openid>/640`), a public endpoint by number
    (`q1.qlogo.cn/g?b=qq&nk=<number>&s=640`). Both were scaled to 16×16
    greyscale, and a root-mean-square difference within 5% counted as the
    same: two pictures of one person differed by 0.03%, different people's
    by 36 to 60%. Accounts without an avatar, and openids that don't exist,
    all return one default picture (1,512 bytes), which never matched.
  - An account resembling an owner's or Max's old number wasn't linked
    and was logged as likely impersonation; two accounts resembling one
    number, or a number already taken in the group, linked neither. Each
    account was compared once, recorded in `avatar_checks`, with old
    numbers' fingerprints in `legacy_avatars`, refetched after 7 days.
  - The risk stayed: anyone can change their avatar, and one switched to an
    absent old member's would be linked as them. The logs were the only
    safeguard.

## Decision

No automatic linking. Migration 0024 undid it without a trace: the 134
accounts it had linked became their own people again (`merged_into`
cleared), the `text` of the 802 rows mentioning them went back to their own
`[mention#id]`, and `legacy_avatars` and `avatar_checks` were dropped. No
merge made by hand existed to keep. Recall vectors needed no recomputing,
as `recall_text` strips handles; turn transcripts, being what the model saw
then, were left as they are. The code is in commit `12d420cb` and earlier.

## Cost

People from old groups are new people in the new groups. Linking one is
done by hand, by editing `principals.merged_into` in the database; users'
own claims aren't trusted.
