命运2（Bungie API）：查发起人的仓库/角色/战绩/商人、按名字查装备和 perk、转移装备——碰到命运2账号相关的事先取这份

# 身份和权限

所有调用都以**发起人自己**的 Bungie 账号进行，宿主自动带上他的授权；你没办法、也不要尝试用别人的账号。
- 先 `destiny_account`：拿到 bungie_name、membership_type、membership_id 和各角色 character_id/职业/光等。
- `linked=false` 时，按返回的 login 告诉对方：私聊我发 `!destiny login`，在浏览器里登录 Bungie
  （Steam/PSN/Xbox/Epic 都行）点批准即可。绝不要在聊天里要 API key、密码、token 或授权码。
- 查别人（群友、主播）只能看公开数据：先搜 Bungie 名拿 membershipId，再读公开组件。对方的仓库、
  背包、商人属于私有数据，没有对方授权看不到——如实说，不要编。
- 64 位 id（membershipId、characterId、itemInstanceId）一律当字符串原样传递，别转成数字。

# 先用现成工作流

`run_code({workflow, args})`：

- `destiny/inventory` `{query?, slot?: all|weapon|armor|gear, limit?, with_perks?, with_stats?}`：在仓库、
  背包、已装备里按中/英文名找物品，给出位置、item_id、光等、元素、锁定/大师/锻造和 perk。
  "我有没有 XX""我仓库里几把 XX""哪把 XX 是 god roll"先用它。
- `destiny/move` `{item_id, to: "vault" | character_id, equip}`：转移（可顺手装备）。正装备着的会先换上
  同栏位另一件（优先非异域），角色之间自动经仓库中转。返回逐步结果。
- `destiny/recent` `{mode?, count?, character_id?}`：最近活动（全部角色合并），含 instance_id。

工作流覆盖不到的，再用 run_code 自己组合 `destiny_read` / `destiny_lookup` / `destiny_write`。
Profile 类响应很大：只在 run_code 里读，`max_chars: 3500000`，在 JS 里筛选后只返回需要的字段。

# 写操作

`destiny_write` 只在发起人明确要求时调用。有多件同名（不同 roll/光等）、会挤掉已装备的异域、
目标角色不明确时，先列出候选复述一遍再执行。一次只做被要求的事，不顺手整理仓库。
结果 outcome-unknown 时先重新读库存核对，不要盲目重试。

body 一律带 `membershipType`（来自 destiny_account），id 用字符串：
- 转移 `/Destiny2/Actions/Items/TransferItem/`：`{itemReferenceHash, stackSize, transferToVault, itemId, characterId}`。
  放进仓库：transferToVault=true、characterId=当前所在角色；取出：false、characterId=目标角色。
  角色之间必须两步经仓库；已装备的物品不能直接转移。
- 装备 `/Destiny2/Actions/Items/EquipItem/` `{itemId, characterId}`；批量 `EquipItems` `{itemIds: [], characterId}`。
  物品必须已在该角色背包里；同时只能装一件异域武器、一件异域护甲。
- 邮政官 `PullFromPostmaster` `{itemReferenceHash, stackSize, itemId, characterId}`（非实例物品 itemId 用 "0"）。
- 锁定 `SetLockState` `{state: true|false, itemId, characterId}`；追踪任务 `SetTrackedState` 同形。
- 免费插件（perk/模组/着色器/装饰/子职业插槽）`InsertSocketPlugFree`
  `{plug: {socketIndex, socketArrayType: 0, plugItemHash}, itemId, characterId}`；插件须在该插槽可用列表里。
- 官方配装 `/Destiny2/Actions/Loadouts/EquipLoadout/` `{loadoutIndex, characterId}`，
  另有 `SnapshotLoadout`、`UpdateLoadoutIdentifiers`、`ClearLoadout`。

# 常用读接口

路径都在 `/Platform` 之后，`destiny_read` 的 path 直接写：
- 档案 `/Destiny2/{mt}/Profile/{mid}/`，`query.components` 常用：100 档案、102 仓库、103 货币、
  104 赛季神器、200 角色、201 背包、202 角色进度、204 当前活动、205 已装备、206 官方配装、
  300 物品实例（光等/元素）、302 物品 perk、304 物品属性、305 当前插槽、309 插件目标（击杀计数）、
  310 可切换的插件（每列可选 perk）、800 收藏、900 成就/称号、1000 当前火力战队、1100 指标、1300 锻造。
  物品级数据在 `itemComponents.<instances|sockets|stats|reusablePlugs>.data[itemInstanceId]`。
- 单件 `/Destiny2/{mt}/Profile/{mid}/Item/{itemInstanceId}/`，components 同上。
- 账号统计 `/Destiny2/{mt}/Account/{mid}/Stats/`（PvE/PvP 生涯：击杀、KD、通关数等）。
- 活动记录 `/Destiny2/{mt}/Account/{mid}/Character/{cid}/Stats/Activities/`，query `{mode, count, page}`。
- 单场结算 PGCR `/Destiny2/Stats/PostGameCarnageReport/{instanceId}/`（全队数据、武器击杀）。
- 角色武器统计 `.../Character/{cid}/Stats/UniqueWeapons/`；活动汇总 `.../Stats/AggregateActivityStats/`。
- 商人（需授权）`/Destiny2/{mt}/Profile/{mid}/Character/{cid}/Vendors/`，components `[400, 402, 300, 305]`；
  单个商人加 `/{vendorHash}/`，仄尔 vendorHash 2190858386。公开商人 `/Destiny2/Vendors/`。
- 周常 `/Destiny2/Milestones/`。战队 `/GroupV2/User/{mt}/{mid}/0/1/`、成员 `/GroupV2/{groupId}/Members/`。
- 搜人（POST，`body`）：`/Destiny2/SearchDestinyPlayerByBungieName/-1/` `{displayName, displayNameCode}`
  （名字#后面四位数字是 code）；按前缀 `/User/Search/GlobalName/0/` `{displayNamePrefix}`。

# 定义（manifest）

响应里只有 hash，名字和含义用 `destiny_lookup` 翻译：`{kind, hashes}` 批量翻译，`{search, kind?}` 按名字找。
kind 简称：item（武器/护甲/模组/perk 插件都在这）、plugset（随机 perk 池）、stat、bucket、activity、mode、
vendor、perk、record、collectible、objective、season、damage、class、set（护甲套装）等。
- item 定义精简字段：type、tier、tierType（6 异域、5 传说）、itemType（3 武器、2 护甲、19 模组）、classType
  （0 泰坦、1 猎人、2 术士、3 通用）、damageType（1 动能、2 电弧、3 烈日、4 虚空、6 冰影、7 缚丝）、
  ammoType（1 主、2 特殊、3 重型）、stats、sockets（index、category、initial、plugSet、randomPlugSet）。
- 武器能出的 perk：item 的 sockets 里 category 4241085061（武器 perk）的 randomPlugSet → 查 plugset 得到
  `plugs: [[hash, 当前能否掉落]]` → 再查 item 翻译名字。3956125808 是固有特性。
- 物品 state 位：1 锁定、2 追踪、4 大师、8 锻造。仓库 bucketHash 138197802，邮政官 215593132。
- 本地 manifest 刚启动时可能还在同步，搜索暂不可用；物品可改用
  `/Destiny2/Armory/Search/DestinyInventoryItemDefinition/{词}/` 搜。

# 常见错误

Bungie 的错误原文会带回来，照实转述：
- DestinyPrivacyRestriction：对方设置了隐私，看不到。
- DestinyCannotPerformActionAtThisLocation / DestinyItemActionForbidden：角色在活动中，需回到轨道或社交区再装备。
- DestinyNoRoomInDestination：仓库或背包满了。
- DestinyUniquenessViolation：已经装着一件同类异域。
- DestinyItemNotFound：物品已移动或分解，重新读一次。
- SystemDisabled：Bungie 维护中，稍后再试。
- 授权过期时工具会提示重新 `!destiny login`。
