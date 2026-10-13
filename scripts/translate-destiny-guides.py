#!/usr/bin/env python3
"""Build the zh/ copies, names.tsv and catalog.tsv for the Destiny guide data.

Python standard library + curl (PyYAML for --llm-config). Official names are
paired by definition hash in Bungie's en/zh-chs Manifest; bare frame labels in
weapon tables use the official frame names. Community prose uses a configured
Max model, or Google's public translation endpoint (machine translation, not
official game text). Protected tokens preserve names, numbers, units, URLs,
newlines and uncertainty markers. Lines translated before are reused from the
local cache, which fetch-destiny-guides.py fills from the checked-in copies;
Max itself never calls a translation service.
"""

import argparse
import collections
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
import urllib.error
from datetime import datetime, timezone
from pathlib import Path

from destiny_guide_files import (GLOSSARY, OVERRIDES, SOURCES_INDEX, TRANSLATION_INDEX, digest, frame_line,
                                 grid_bytes, harvest_memory, open_memory, read_grid, zh_path)


ROOT = Path(__file__).resolve().parent.parent
KINDS = ["DestinyInventoryItemDefinition", "DestinySandboxPerkDefinition",
         "DestinyEquipableItemSetDefinition", "DestinyClassDefinition",
         "DestinyDamageTypeDefinition", "DestinyStatDefinition", "DestinyBreakerTypeDefinition"]
# A seconds suffix (6s, 15.8s) is part of the value; translation used to drop it.
NUMERIC_VALUE = r"(?:\d[\d,]*(?:\.[\d?]+)?(?:[eE][+-]?\d+)?\?*|\?+)(?:%|x|×|s(?![A-Za-z]))?"
NUMERIC_EXPRESSION = r"(?<![A-Za-z0-9])[-+↑↓~<>≤≥=]*" + NUMERIC_VALUE + r"(?:\s*[-+↑↓~/|<>≤≥=]+\s*[-+]?" + NUMERIC_VALUE + r")*"
PROTECTED = re.compile(r"ZXQT\d+QXZ|https?://[^\s]+|@[\w.-]+|\n|(?<![\w])[A-Za-z_]{1,32}\d+[A-Za-z0-9_.+-]*|" + NUMERIC_EXPRESSION + r"|[%~?↑↓≤≥≈]")
TOKEN = re.compile(r"ZXQT\d+QXZ")
SEGMENT = re.compile(r"ZXQSEG(\d+)QXZ")
# Kept verbatim. N/A and INF are cell values that numeric code must recognise.
TECHNICAL = {"PvE": "PvE", "PvP": "PvP", "PVE": "PvE", "PVP": "PvP", "DPS": "DPS",
             "TtE": "TtE", "RPM": "RPM", "DIM": "DIM", "API": "API", "HP": "HP",
             "N/A": "N/A", "n/a": "n/a", "INF": "INF"}
KIND_NAMES = {"DestinyInventoryItemDefinition": "item", "DestinySandboxPerkDefinition": "perk",
              "DestinyEquipableItemSetDefinition": "set", "DestinyClassDefinition": "class",
              "DestinyDamageTypeDefinition": "damage", "DestinyStatDefinition": "stat",
              "DestinyBreakerTypeDefinition": "breaker"}
# Outputs this script owns; the English side belongs to fetch-destiny-guides.py.
MANAGED = ["zh", "archive/zh", "names.tsv", "catalog.tsv", TRANSLATION_INDEX.as_posix(), GLOSSARY.as_posix()]
# Editorial terms are kept separate from the official-name dictionary.
EDITORIAL = {"Perk": "特性", "Perks": "特性", "Enhanced": "强化", "Boss": "首领",
             "Bosses": "首领", "Champions": "勇士", "Sustained": "持续输出", "Swap": "切枪",
             "Fireteam": "火力战队", "TtE": "打空弹药时间 TtE", "Abilties": "技能",
             "Set Bonuses": "护甲套装效果", "Weapon Perks": "武器特性",
             "Exotic Armors": "异域护甲", "Exotic Weapons": "异域武器",
             "Powered Melee": "充能近战", "Powered Melees": "充能近战",
             "Combatants": "战斗人员", "Precision Hits": "精准命中", "Precision Hit": "精准命中",
             "Damage Resistance": "伤害抗性", "Damage Reduction": "伤害减免",
             "Reload Speed": "换弹速度", "Ready Speed": "举枪速度", "Stow Speed": "收枪速度",
             "Ignitions": "点燃", "Ignition": "点燃", "Scorch": "灼烧",
             "Overshield": "额外护盾", "Overshields": "额外护盾",
             "Prismatic": "棱镜", "Restoration": "复原", "Resilience": "韧性",
             "Intellect": "智慧", "Discipline": "纪律"}
EDITORIAL.update({
    "Reload": "换弹", "Reloading": "换弹", "Reloads": "换弹", "Power": "威能",
    "Weapons of Light": "光之武器", "Weapon Damage": "武器伤害", "Weapon": "武器", "Weapons": "武器",
    "Arc Damage": "电弧伤害", "Solar Damage": "烈日伤害", "Void Damage": "虚空伤害",
    "Kinetic Damage": "动能伤害", "Stasis Damage": "冰影伤害", "Strand Damage": "缚丝伤害",
    "Arc": "电弧", "Solar": "烈日", "Void": "虚空", "Kinetic": "动能",
    "Transcendence": "超凡", "Sever": "切断", "Slow": "减速", "Blind": "致盲", "Weaken": "削弱",
    "Suppression": "压制", "Suppress": "压制", "Volatile": "易爆", "Jolt": "震颤",
    "Unravel": "瓦解", "Suspend": "悬停", "Freeze": "冻结", "Frozen": "冻结", "Shatter": "碎裂",
    "Stacks": "层数", "Stack": "层数", "Kills": "击杀", "Kill": "击杀",
    "Final Blows": "最后一击", "Final Blow": "最后一击", "Rank-and-File": "普通敌人",
    "Miniboss": "小首领", "Guardians": "守护者", "Damage": "伤害", "Buff": "增益", "Debuff": "减益",
    "Grenade": "手雷", "Grenades": "手雷", "Melee": "近战", "Super": "超能", "Class Ability": "职业技能",
    "Grenade Energy": "手雷能量", "Melee Energy": "近战能量", "Super Energy": "超能能量",
    "Class Ability Energy": "职业技能能量", "Damage Falloff": "伤害衰减",
    "Lightweight": "轻质", "Aggressive": "攻击型", "Adaptive": "适配型", "Precision": "精准",
    "Auto Rifle": "自动步枪", "Hand Cannon": "手炮", "Pulse Rifle": "脉冲步枪",
    "Scout Rifle": "斥候步枪", "Sidearm": "手枪", "Submachine Gun": "微型冲锋枪",
    "Fusion Rifle": "融合步枪", "Linear Fusion Rifle": "线性融合步枪", "Shotgun": "霰弹枪",
    "Sniper Rifle": "狙击步枪", "Trace Rifle": "追踪步枪", "Combat Bow": "战斗弓",
    "Machine Gun": "机枪", "Rocket Launcher": "火箭发射器", "Grenade Launcher": "榴弹发射器",
    "Glaive": "偃月", "Sword": "刀剑", "Normal": "普通", "Enhanced Trait": "强化特性",
    "Landing": "首页", "LANDING": "首页", "Home": "首页", "Status": "状态",
    "Changelog": "更新记录", "FAQ": "常见问题", "Reference": "参考资料", "Equipment": "装备",
    "STACKING GUIDE": "叠加规则指南", "CHAMP COUNTERS LIST": "勇士应对列表", "CATALYSTS": "催化剂",
    "BANES": "Banes（敌人词缀）", "MICRO-MISSILES": "微型导弹", "COMBATANTS GUIDE": "敌人分类指南",
    "Armor Perks": "护甲特性", "Artifact Perks": "神器特性", "Armor Mods": "护甲模组",
    "Exotic Class": "异域职业物品", "Class Abilities": "职业技能", "Game Mechanics": "游戏机制",
    "Episodic Artifact Perks": "章节神器特性", "Seasonal Artifact Perks": "赛季神器特性",
    "Nether Mechanics": "幽冥机制", "Shopping List": "推荐获取清单", "Archetypes": "武器框架和类型",
    "Ideas": "想法", "Experimental": "实验方案", "Autos": "自动步枪", "Bows": "战斗弓",
    "HCs": "手炮", "Pulses": "脉冲步枪", "Scouts": "斥候步枪", "Sidearms": "手枪",
    "SMGs": "微型冲锋枪", "BGLs": "后膛装填榴弹发射器", "Fusions": "融合步枪", "Glaives": "偃月",
    "Shotguns": "霰弹枪", "Snipers": "狙击步枪", "Rocket Sidearms": "火箭框架手枪", "Traces": "追踪步枪",
    "HGLs": "重型榴弹发射器", "LFRs": "线性融合步枪", "LMGs": "机枪", "Rockets": "火箭发射器",
    "Swords": "刀剑", "Other": "其他", "Primaries": "主要弹药武器", "Exotic Armor": "异域护甲",
    "Builds": "配装", "Origin Traits": "起源特性", "Artifact Mods": "神器模组", "Fragments": "碎片",
    "Aspects": "星象", "Subclasses": "子职业", "Encounters": "关卡", "Abilities": "技能",
    "Scaling": "伤害缩放", "Graphing": "图表", "Historical": "历史记录", "Testing": "测试",
    "Name": "名称", "Type": "类型", "Notes": "说明", "Description": "描述", "Tier": "评级",
    "Source": "来源", "Frame": "框架", "Effect": "效果", "Trigger": "触发条件", "Date": "日期",
    "Updated": "更新时间", "Pcs": "件数", "Total": "总计", "Energy": "能量", "Season": "赛季",
})
LLM = None


def dump(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def download(url, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["curl", "-fLsS", "--retry", "2", "--max-time", "180", url, "-o", str(path)], check=True)


def official_terms(cache):
    manifest_file = cache / "manifest.json"
    if not manifest_file.exists():
        download("https://www.bungie.net/Platform/Destiny2/Manifest/", manifest_file)
    manifest = json.loads(manifest_file.read_text())["Response"]
    version = manifest["version"]
    term_file = cache / f"terms-ui-priority-{digest(version.encode())[:16]}.json"
    if term_file.exists():
        return version, json.loads(term_file.read_text())
    candidates = collections.defaultdict(list)
    for kind in KINDS:
        names = {}
        for language in ["en", "zh-chs"]:
            path = cache / version / f"{kind}-{language}.json"
            if not path.exists():
                download("https://www.bungie.net" + manifest["jsonWorldComponentContentPaths"][language][kind], path)
            definitions = json.loads(path.read_text())
            for key, definition in definitions.items():
                if kind == "DestinyInventoryItemDefinition" and definition.get("itemType") not in [2, 3, 19]:
                    continue
                name = definition.get("displayProperties", {}).get("name", "").strip()
                if language == "en":
                    names[key] = name
                elif name and names.get(key) and re.search(r"[\u3400-\u9fff]", name):
                    candidates[names[key]].append({"zh_chs": name, "kind": kind, "hash": key})
            del definitions
    # Same English label may represent different definitions; do not invent a
    # Chinese identity when their official names disagree.
    terms = {}
    for name, values in candidates.items():
        # Inventory plug names are the names players see. Sandbox descriptions
        # sometimes use a different label for the same English word.
        preferred = [value for value in values if value["kind"] == "DestinyInventoryItemDefinition"] or values
        terms[name] = preferred
    dump(term_file, terms)
    return version, terms


def term_matcher(terms):
    names = sorted(terms, key=lambda name: (-len(name), name))
    return re.compile(r"(?<![\w])(?:" + "|".join(re.escape(name) for name in names) + r")(?![\w])")


def render_term(name, values):
    names = sorted({value["zh_chs"] for value in values})
    return names[0] if len(names) == 1 else " / ".join(names) + f"（{name}）"


def protect(text, terms, matcher):
    values = []

    def token(value):
        marker = f"ZXQT{len(values):04d}QXZ"
        values.append(value)
        return marker

    prepared = re.sub(r"https?://[^\s]+|@[\w.-]+|\n", lambda m: " " + token(m[0]) + " ", text)
    # Give the model readable mechanics vocabulary; opaque tokens are reserved
    # for identities and data that must remain exact.
    prepared = matcher.sub(lambda m: " " + terms[m[0]] + " " if m[0] in EDITORIAL and m[0] not in TECHNICAL else token(terms[m[0]]), prepared)
    prepared = PROTECTED.sub(lambda m: m[0] if TOKEN.fullmatch(m[0]) else token(m[0]), prepared)
    return prepared, values


def restore(translated, values, original, prepared):
    # Formatting added by a model is not part of the source's paragraph grid.
    # The protected newline tokens restore exactly the original structure.
    translated = translated.replace("\r\n", " ").replace("\n", " ")
    translated = re.sub(r"ZXQT\s*(\d+)\s*QXZ", lambda m: f"ZXQT{int(m[1]):04d}QXZ", translated, flags=re.I)
    expected = collections.Counter(f"ZXQT{i:04d}QXZ" for i in range(len(values)))
    for marker, value in zip(expected, values):
        if value.endswith(("%", "x")):
            translated = re.sub(re.escape(marker) + r"\s*" + re.escape(value[-1]), marker, translated)
    actual = collections.Counter(TOKEN.findall(translated))
    if not actual - expected:
        # A model sometimes spells out a supplied value (e.g. 射程) instead of
        # its marker. Accept only exact literals with an unambiguous count;
        # never guess, substitute synonyms, or repair a missing numeric value.
        expanded = collections.defaultdict(list)
        for marker in expected - actual:
            expanded[values[int(re.search(r"\d+", marker)[0])]].append(marker)
        for value, markers in sorted(expanded.items(), key=lambda pair: -len(pair[0])):
            if not value.strip():
                continue
            masked = TOKEN.sub(lambda m: " " * len(m[0]), translated)
            prefix = r"(?<![A-Za-z0-9])" if value[0].isascii() and value[0].isalnum() else ""
            suffix = r"(?![A-Za-z0-9])" if value[-1].isascii() and value[-1].isalnum() else ""
            matches = list(re.finditer(prefix + re.escape(value) + suffix, masked))
            if len(matches) == len(markers):
                for match, marker in reversed(list(zip(matches, markers))):
                    translated = translated[:match.start()] + marker + translated[match.end():]
    if collections.Counter(TOKEN.findall(translated)) != expected:
        raise ValueError("Translation changed a protected token")
    def value_for(m):
        value = values[int(re.search(r"\d+", m[0])[0])]
        return " " + value + " " if value.startswith(("https://", "http://")) else value
    restored = TOKEN.sub(value_for, translated).strip()
    restored = re.sub(r"(?<=[\u3400-\u9fff]) +(?=[\u3400-\u9fff])", "", restored)
    # Preserve source whitespace at the edges, including blank spreadsheet lines.
    restored = re.match(r"\s*", original)[0] + restored + re.search(r"\s*$", original)[0]
    if original.count("\n") != restored.count("\n"):
        raise ValueError("Translation changed line structure")
    # Official entity names can localize numerals (Fr0st-EE5 -> 冰霜-EE5).
    # Validate the expected official substitution, then all remaining numbers.
    expected_text = TOKEN.sub(lambda m: values[int(re.search(r"\d+", m[0])[0])], prepared)
    source_numbers = collections.Counter(re.findall(r"\d+(?:[.,]\d+)*%?", expected_text))
    output_numbers = collections.Counter(re.findall(r"\d+(?:[.,]\d+)*%?", restored))
    if source_numbers != output_numbers:
        raise ValueError("Translation changed numbers")
    markers = "%?~↑↓≤≥≈"
    if collections.Counter(c for c in expected_text if c in markers) != collections.Counter(c for c in restored if c in markers):
        raise ValueError("Translation changed a percentage or uncertainty marker")
    if original.strip() and not restored.strip():
        raise ValueError("Translation removed nonempty text")
    return restored


def translate_batch(batch):
    if LLM is not None:
        return translate_model(batch)
    payload = "\n".join(f"ZXQSEG{i:04d}QXZ\n{prepared}" for i, (_, prepared, _) in enumerate(batch))
    url = "https://translate.googleapis.com/translate_a/single?" + urllib.parse.urlencode(
        {"client": "gtx", "sl": "en", "tl": "zh-CN", "dt": "t", "q": payload})
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    result = json.load(urllib.request.urlopen(request, timeout=45))
    translated = "".join(part[0] for part in result[0] if part[0])
    markers = list(SEGMENT.finditer(translated))
    if [int(m[1]) for m in markers] != list(range(len(batch))):
        raise ValueError("Translation changed batch boundaries")
    outputs = []
    for i, (original, prepared, values) in enumerate(batch):
        end = markers[i + 1].start() if i + 1 < len(markers) else len(translated)
        outputs.append((original, restore(translated[markers[i].end():end], values, original, prepared)))
    return outputs


def translate_model(batch):
    system = (
        "你是命运2攻略的简体中文译者。翻译社区测试说明、表头和名称，准确保留条件、否定、例外、"
        "时间单位、测试前提和不确定性，不总结或增补。每项 text 中 ZXQTnnnnQXZ 是受保护占位符，"
        "tokens 提供它的含义（官方名称、数字、链接、换行等），便于理解。输出必须保留每一个占位符"
        "一次，不展开、不修改、不新增占位符，不把 tokens 的数字/名称另行写入文本。换行由占位符表示，"
        "不要增加实际换行；链接占位符两侧保留空格。不得新增阿拉伯数字，one/two 等英文数词用中文数词翻译。"
        "text 中已有的中文术语请沿用。表格用 e. 前缀表示强化版（Enhanced），e. Target Lock 译为强化目标锁定，"
        "不是“例如”。术语词典外无法确认官方译名的游戏专名保留英文，"
        "普通说明和表头完整译为中文，使用自然中文语序，如伤害提高XYZ。按完整原文翻译，"
        "可调整中文语序。仅返回 JSON 对象 {\"translations\":[\"译文0\",\"译文1\",...]}，顺序和数量与输入相同。"
    )
    items = [{"text": prepared, "tokens": {f"ZXQT{i:04d}QXZ": value for i, value in enumerate(values)}}
             for _, prepared, values in batch]
    content = json.dumps({"items": items}, ensure_ascii=False)
    protocol = LLM.get("protocol", "openai")
    headers = {"Content-Type": "application/json", "Authorization": "Bearer " + LLM["api_key"]}
    body = {"model": LLM["model"], "stream": False}
    if protocol == "anthropic":
        suffix = "/v1/messages"
        headers = {"Content-Type": "application/json", "x-api-key": LLM["api_key"], "anthropic-version": "2023-06-01"}
        body.update(system=system, messages=[{"role": "user", "content": content}], max_tokens=8192)
    elif protocol == "responses":
        suffix = "/responses"
        body.update(instructions=system, input=content, max_output_tokens=8192)
        if LLM.get("effort"):
            body["reasoning"] = {"effort": LLM["effort"]}
    else:
        suffix = "/chat/completions"
        body.update(messages=[{"role": "system", "content": system}, {"role": "user", "content": content}], max_tokens=8192)
        if LLM.get("effort"):
            body["reasoning_effort"] = LLM["effort"]
    request = urllib.request.Request(LLM["base_url"].rstrip("/") + suffix,
                                     data=json.dumps(body, ensure_ascii=False).encode(), headers=headers)
    result = json.load(urllib.request.urlopen(request, timeout=LLM.get("timeout_seconds", 180)))
    if protocol == "anthropic":
        text = "".join(part.get("text", "") for part in result["content"])
    elif protocol == "responses":
        text = "".join(part.get("text", "") for output in result["output"] for part in output.get("content", []))
    else:
        text = result["choices"][0]["message"]["content"]
    text = re.sub(r"^```(?:json)?\s*|\s*```$", "", text.strip())
    translations = json.loads(text)["translations"]
    if len(translations) != len(batch) or not all(isinstance(value, str) for value in translations):
        raise ValueError("Translation changed batch boundaries")
    outputs = []
    for item, value in zip(batch, translations):
        original, prepared, values = item
        try:
            outputs.append((original, restore(value, values, original, prepared)))
        except ValueError as error:
            path = ROOT / "var/destiny-guides-translation/failures" / (digest(original.encode()) + ".json")
            dump(path, {"error": str(error), "original": original, "prepared": prepared, "tokens": values, "translation": value})
            if len(batch) > 1:
                outputs.extend(translate_retry([item]))
            else:
                raise
    return outputs


def translate_retry(batch):
    for attempt in range(3):
        try:
            return translate_batch(batch)
        except ValueError:
            if len(batch) > 1:
                break
        except urllib.error.HTTPError as error:
            # Do not fan a rate limit out into hundreds of smaller requests.
            if error.code in [401, 403, 429]:
                raise RuntimeError(f"Translation provider returned HTTP {error.code}; configure an available model or retry later") from None
            if attempt < 2:
                time.sleep(1 + attempt * 2)
        except Exception:
            if attempt < 2:
                time.sleep(1 + attempt * 2)
    if len(batch) > 1:
        middle = len(batch) // 2
        return translate_retry(batch[:middle]) + translate_retry(batch[middle:])
    raise RuntimeError(f"Cannot validate translation for cell {digest(batch[0][0].encode())[:16]}: {batch[0][0][:120]!r}")


def frame_names(official):
    """Bare frame labels -> official short names, e.g. High-Impact -> 高冲击力."""
    frames = {}
    for name, values in official.items():
        names = {value["zh_chs"] for value in values}
        if name.endswith(" Frame") and len(names) == 1 and next(iter(names)).endswith("框架"):
            frames[name[: -len(" Frame")]] = next(iter(names))[: -len("框架")]
    return frames


def tsv(fields):
    return "\t".join(re.sub(r"[\t\r\n]+", " ", str(field)) for field in fields) + "\n"


def sheet_status(sheet):
    if sheet["current"]:
        return "current"
    return sheet["source_status"] if sheet["source_status"] != "unspecified" else sheet["visibility"]


def build_catalog(index, records):
    """catalog.tsv: the first file to read; current sheets first per workbook."""
    titles = {record["path"]: record["title_zh"] for record in records}
    lines = [tsv(["path", "source", "title", "title_zh", "status", "rows", "columns", "header_rows", "fetched_at", "url"])]
    for source in index["sources"]:
        for sheet in sorted(source["sheets"], key=lambda sheet: not sheet["current"]):
            lines.append(tsv([sheet["path"], source["id"], sheet["title"], titles[sheet["path"]], sheet_status(sheet),
                              sheet["rows"], sheet["columns"], ",".join(map(str, sheet["header_rows"])),
                              sheet["fetched_at"], sheet["source_url"]]))
    return "".join(lines).encode("utf-8")


def build_names(glossary):
    """names.tsv: English term -> official (or editorial) Chinese, with hashes."""
    rows = []
    for name, values in glossary["official_terms"].items():
        by_name = collections.defaultdict(list)
        for value in values:
            by_name[value["zh_chs"]].append(value)
        for zh, group in by_name.items():
            kinds = sorted({KIND_NAMES.get(value["kind"], value["kind"]) for value in group})
            rows.append((name, zh, ",".join(kinds), ",".join(value["hash"] for value in group)))
    rows += [(name, zh, "frame", "") for name, zh in glossary["frame_terms"].items()]
    rows += [(name, zh, "editorial", "") for name, zh in glossary["editorial_terms"].items() if name != zh]
    rows.sort(key=lambda row: (row[0].casefold(), row[0], row[2], row[1]))
    return "".join(tsv(row) for row in [("en", "zh", "kind", "hash")] + rows).encode("utf-8")


def check(data):
    """Validate the installed copies without network access."""
    index = json.loads((data / SOURCES_INDEX).read_text())
    local = json.loads((data / TRANSLATION_INDEX).read_text())
    glossary = json.loads((data / GLOSSARY).read_text())
    terms = {name: render_term(name, values) for name, values in glossary["official_terms"].items()}
    terms.update(glossary["editorial_terms"])
    matcher = term_matcher(terms)
    records = {record["path"]: record for record in local["sheets"]}
    expected_files = set()
    for source in index["sources"]:
        for sheet in source["sheets"]:
            record = records.pop(sheet["path"])
            raw = (data / sheet["path"]).read_bytes()
            translated = (data / record["zh_path"]).read_bytes()
            assert digest(raw) == sheet["sha256"] == record["original_sha256"], sheet["path"]
            assert digest(translated) == record["sha256"], record["zh_path"]
            assert record["zh_path"] == zh_path(sheet["path"])
            expected_files.update([sheet["path"], record["zh_path"], sheet["meta_path"]])
            a, b = read_grid(data / sheet["path"]), read_grid(data / record["zh_path"])
            assert raw.count(b"\n") == len(a) == len(b) == sheet["rows"], sheet["path"]
            for left, right in zip(a, b):
                assert len(left) == len(right) == sheet["columns"], sheet["path"]
                for en, zh in zip(left, right):
                    assert bool(en) == bool(zh)
                    assert en.count("\n") == zh.count("\n")
                    expected = matcher.sub(lambda m: terms[m[0]], en)
                    assert collections.Counter(re.findall(r"\d+(?:[.,]\d+)*%?", expected)) == collections.Counter(re.findall(r"\d+(?:[.,]\d+)*%?", zh)), (sheet["path"], en, zh)
                    markers = "%?~↑↓≤≥≈"
                    assert collections.Counter(c for c in expected if c in markers) == collections.Counter(c for c in zh if c in markers), (sheet["path"], en, zh)
                    assert re.findall(r"https?://[^\s]+", en) == re.findall(r"https?://[^\s]+", zh)
                    assert not TOKEN.search(zh) and not SEGMENT.search(zh)
    assert not records, sorted(records)
    installed = {path.relative_to(data).as_posix() for top in ["en", "zh", "archive", "meta"]
                 for path in (data / top).rglob("*") if path.is_file()}
    assert installed == expected_files, sorted(installed ^ expected_files)
    assert (data / "catalog.tsv").read_bytes() == build_catalog(index, local["sheets"]), "catalog.tsv is stale"
    assert (data / "names.tsv").read_bytes() == build_names(glossary), "names.tsv is stale"
    print(f"Validated {len(local['sheets'])} bilingual CSVs: hashes, coordinates, empty cells, numbers, URLs, newlines, catalog and names")


def main():
    global LLM
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, default=ROOT / "data/destiny-guides")
    parser.add_argument("--cache", type=Path, default=ROOT / "var/destiny-guides-translation")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--llm-config", type=Path, help="Existing Max YAML config; requires PyYAML; never prints credentials")
    parser.add_argument("--profile", help="Max LLM profile (defaults to llm.default)")
    parser.add_argument("--llm-env", action="store_true", help="Use MAX_LLM_API_KEY/BASE_URL/MODEL/PROTOCOL")
    parser.add_argument("--terms-only", action="store_true", help="Build an explicitly marked terminology draft; leave new community prose in English")
    parser.add_argument("--no-memory", action="store_true", help="Translate every line again instead of reusing earlier translations")
    parser.add_argument("--retranslate", type=re.compile, metavar="REGEX", help="Translate lines matching REGEX again instead of reusing earlier translations")
    parser.add_argument("--plan", action="store_true", help="Report the lines that would need translation, without translating or writing")
    parser.add_argument("--check", action="store_true", help="Validate installed copies without network access")
    args = parser.parse_args()
    if args.check:
        check(args.data)
        return
    if args.terms_only and (args.llm_config or args.llm_env):
        parser.error("--terms-only cannot be combined with a translation model")
    if args.llm_config:
        import yaml
        settings = yaml.safe_load(args.llm_config.read_text())["llm"]
        LLM = settings["profiles"][args.profile or settings["default"]]
    elif args.llm_env:
        LLM = {"api_key": os.environ["MAX_LLM_API_KEY"], "base_url": os.environ["MAX_LLM_BASE_URL"],
               "model": os.environ["MAX_LLM_MODEL"], "protocol": os.environ.get("MAX_LLM_PROTOCOL", "openai"),
               "effort": os.environ.get("MAX_LLM_EFFORT")}
    if LLM is not None:
        if not all(LLM.get(key) for key in ["api_key", "base_url", "model"]):
            raise ValueError("Translation profile needs api_key, base_url and model")
        print("Translation model:", LLM["model"], flush=True)
    args.cache.mkdir(parents=True, exist_ok=True)
    version, official = official_terms(args.cache)
    terms = {name: render_term(name, values) for name, values in official.items()}
    terms.update(EDITORIAL)
    terms.update(TECHNICAL)
    matcher = term_matcher(terms)
    frames = frame_names(official)
    index = json.loads((args.data / SOURCES_INDEX).read_text())
    db = open_memory(args.cache)
    # A rerun without a fetch reuses the copies it is about to replace.
    harvest_memory(args.data, db)
    memory = {} if args.no_memory else dict(db.execute("SELECT original, translated FROM memory"))
    overrides = json.loads((args.data / OVERRIDES).read_text()) if (args.data / OVERRIDES).exists() else {}
    catalog, units, used_frames = [], set(), set()
    for source in index["sources"]:
        for sheet in source["sheets"]:
            raw = (args.data / sheet["path"]).read_bytes()
            assert digest(raw) == sheet["sha256"], sheet["path"]
            rows = read_grid(args.data / sheet["path"])
            catalog.append((source, sheet, rows))
            units.add(sheet["title"])
            for row in rows:
                for value in row:
                    for line in value.split("\n"):
                        if frame_line(source["id"], line, frames):
                            used_frames.add(line.strip())
                        else:
                            units.add(line)
    # One unit per source line: empty lines stay empty and join back into the
    # exact cell grid, and a changed cell reuses its unchanged lines.
    translated, pending, used, reused, corrected = {}, [], set(), 0, set()
    for text in sorted(units):
        used.update(m[0] for m in matcher.finditer(text))
        if not text.strip():
            translated[text] = text
            continue
        prepared, values = protect(text, terms, matcher)
        if text in overrides:
            translated[text] = overrides[text]
            corrected.add(text)
        elif not re.search(r"[a-zA-Z]", TOKEN.sub("", prepared)):
            translated[text] = restore(prepared, values, text, prepared)
        elif text in memory and not (args.retranslate and args.retranslate.search(text)):
            translated[text] = memory[text]
            reused += 1
        elif args.terms_only:
            translated[text] = restore(prepared, values, text, prepared)
            pending.append((text, prepared, values))
        else:
            pending.append((text, prepared, values))
    # Stay below the public endpoint's URL limit, including UTF-8 encoding.
    batches, batch, size = [], [], 0
    for item in ([] if args.terms_only else pending):
        item_size = len(urllib.parse.quote(item[1])) + 50
        if batch and size + item_size > 6500:
            batches.append(batch)
            batch, size = [], 0
        batch.append(item)
        size += item_size
    if batch:
        batches.append(batch)
    provider = LLM["model"] if LLM else "Google Translate public web endpoint"
    print(f"Official manifest {version}; {len(units)} unique lines; {reused} reused; {len(corrected)} reviewed; {len(pending)} need prose translation in {len(batches)} batches", flush=True)
    for text in sorted(set(overrides) - corrected):
        print("Unused override (English line no longer present): " + json.dumps(text, ensure_ascii=False), flush=True)
    if args.plan:
        for text, _, _ in pending:
            print("  " + json.dumps(text, ensure_ascii=False))
        print("Frame labels:", json.dumps({name: frames[name] for name in sorted(used_frames)}, ensure_ascii=False))
        return
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=args.workers)
    try:
        futures = [pool.submit(translate_retry, batch) for batch in batches]
        for number, future in enumerate(concurrent.futures.as_completed(futures), 1):
            results = future.result()
            translated.update(results)
            db.executemany("INSERT OR REPLACE INTO memory VALUES(?,?)", results)
            db.commit()
            if number % 5 == 0 or number == len(batches):
                print(f"Translated {number}/{len(batches)} batches", flush=True)
    except BaseException:
        pool.shutdown(wait=False, cancel_futures=True)
        raise
    else:
        pool.shutdown(wait=True)
    db.close()

    def localize(source_id, value):
        return "\n".join(frame_line(source_id, line, frames) or translated[line] for line in value.split("\n"))

    with tempfile.TemporaryDirectory(prefix="max-destiny-zh-") as temp:
        stage = Path(temp)
        records = []
        for source, sheet, rows in catalog:
            target = stage / zh_path(sheet["path"])
            target.parent.mkdir(parents=True, exist_ok=True)
            raw = grid_bytes([[localize(source["id"], value) for value in row] for row in rows])
            target.write_bytes(raw)
            title = translated[sheet["title"]]
            if args.terms_only:
                title = re.sub(r"\bOLD\s+", "旧版：", title)
                for en, zh in {"(NOT UPDATED)": "（未更新）", "(outdated)": "（已过时）", "(old)": "（旧版）",
                               "(Old)": "（旧版）", "(old 2)": "（旧版 2）", "(ignore)": "（忽略）",
                               "(breech)": "（后膛装填）", "(drum)": "（弹鼓）"}.items():
                    title = title.replace(en, zh)
            records.append({"source": source["id"], "path": sheet["path"], "zh_path": zh_path(sheet["path"]),
                            "title": sheet["title"], "title_zh": title, "sha256": digest(raw), "original_sha256": sheet["sha256"]})
        glossary = {"manifest_version": version, "source": "https://www.bungie.net/Platform/Destiny2/Manifest/",
                    "official_terms": {name: official[name] for name in sorted(used) if name in official and name not in EDITORIAL and name not in TECHNICAL},
                    "editorial_terms": {name: terms[name] for name in sorted(used) if name in EDITORIAL or name in TECHNICAL},
                    "frame_terms": {name: frames[name] for name in sorted(used_frames)}}
        dump(stage / GLOSSARY, glossary)
        method = ("Terminology draft: official names matched by Bungie definition hash; editorial terms substituted; new community prose remains English pending translation."
                  if args.terms_only else f"Official names matched by Bungie definition hash; frame labels use official frame names; community prose machine-translated: {reused} unchanged lines reuse earlier translations, {len(corrected)} use reviewed lines from {OVERRIDES.as_posix()}, {len(pending)} new lines by {provider}. Not an official translation of the guides.")
        dump(stage / TRANSLATION_INDEX, {"format_version": 2, "language": "zh-chs", "status": "terms-only" if args.terms_only else "complete",
                                         "pending_text_cells": len(pending) if args.terms_only else 0,
                                         "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                                         "manifest_version": version, "original_snapshot": index["generated_at"], "method": method,
                                         "validation": "Original SHA-256, row/column coordinates, empty cells, numeric tokens, URLs, newlines and protected tokens checked; original English retained for review.",
                                         "frames": glossary["frame_terms"], "sheets": records})
        (stage / "names.tsv").write_bytes(build_names(glossary))
        (stage / "catalog.tsv").write_bytes(build_catalog(index, records))
        for relative in MANAGED:
            target = args.data / relative
            if target.is_dir():
                shutil.rmtree(target)
            elif target.exists():
                target.unlink()
        shutil.copytree(stage, args.data, dirs_exist_ok=True)
    print(f"Wrote {len(records)} Chinese CSV copies, names.tsv and catalog.tsv; English originals unchanged", flush=True)


if __name__ == "__main__":
    main()
