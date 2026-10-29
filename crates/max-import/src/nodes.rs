//! The old v2 `canonical_content` nodes as maxx's `Node`s. A forward's
//! messages were rows of their own; they fold into their container here,
//! one line each, as maxx stores a forward now.

use std::collections::{BTreeMap, HashMap};

use color_eyre::eyre::{Result, bail, eyre};
use max_core::ids::{IdentityId, PrincipalId};
use max_core::message::{
    Card, Emote, ForwardRef, MediaKind, MediaMeta, MediaRef, MentionTarget, Node, Platform,
    Unsupported,
};
use serde_json::Value;

/// A forwarded message, folded into its container.
pub struct Child {
    pub id: i64,
    pub name: String,
    pub nodes: Vec<Value>,
}

/// A row's nodes, and where each old media node went.
#[derive(Debug, Default, PartialEq)]
pub struct Converted {
    pub nodes: Vec<Node>,
    /// (old row, index in its old nodes) → ordinal among the media here.
    pub media: Vec<((i64, i32), u16)>,
}

pub struct Converter<'a> {
    /// Each container's messages, in order.
    pub children: &'a HashMap<i64, Vec<Child>>,
    /// The identities that came along; a mention of another is text.
    pub identities: &'a BTreeMap<IdentityId, PrincipalId>,
}

impl Converter<'_> {
    pub fn convert(&self, id: i64, old: &[Value]) -> Result<Converted> {
        let mut out = Converted::default();
        self.walk(id, old, 0, &mut out)
            .map_err(|error| error.wrap_err(format!("message {id}")))?;
        out.nodes = joined(out.nodes);
        Ok(out)
    }

    fn walk(&self, id: i64, old: &[Value], depth: usize, out: &mut Converted) -> Result<()> {
        let mut forwards = 0;
        for (index, node) in old.iter().enumerate() {
            let text = |key| string(node, key);
            match node["type"].as_str() {
                Some("text") => out.nodes.push(Node::Text {
                    text: text("text").unwrap_or_default(),
                }),
                Some("mention") => out.nodes.push(self.mention(node)?),
                Some("emote") => out.nodes.push(Node::Emote(Emote {
                    platform: Platform::QqLegacy,
                    id: text("native_id").ok_or_else(|| eyre!("an emote without an id"))?,
                    name: text("name"),
                })),
                Some("media") => {
                    let ordinal = out
                        .nodes
                        .iter()
                        .filter(|node| matches!(node, Node::Media { .. }))
                        .count();
                    let index = i32::try_from(index)?;
                    out.media.push(((id, index), u16::try_from(ordinal)?));
                    out.nodes.push(medium(node)?);
                }
                Some("card") => out.nodes.push(Node::Card(Card {
                    tag: text("tag"),
                    title: text("title"),
                    subtitle: text("subtitle"),
                    url: text("url"),
                })),
                Some("forward") => {
                    forwards += 1;
                    if forwards > 1 {
                        bail!("two forwards in one message");
                    }
                    let children = self.children.get(&id).map_or(&[][..], Vec::as_slice);
                    out.nodes.push(Node::Forward(ForwardRef {
                        native_id: text("native_id").unwrap_or_default(),
                        count: (!children.is_empty())
                            .then(|| u32::try_from(children.len()))
                            .transpose()?,
                    }));
                    if !children.is_empty() {
                        out.nodes.push(Node::Text { text: "\n".into() });
                    }
                    for child in children {
                        let indent = "  ".repeat(depth);
                        out.nodes.push(Node::Text {
                            text: format!("{indent}{}：", child.name),
                        });
                        self.walk(child.id, &child.nodes, depth + 1, out)?;
                        out.nodes.push(Node::Text { text: "\n".into() });
                    }
                }
                Some("unsupported") => out.nodes.push(Node::Unsupported(Unsupported {
                    source: text("source").unwrap_or_default(),
                    description: text("description").unwrap_or_default(),
                })),
                other => bail!("a node of type {other:?}"),
            }
        }
        Ok(())
    }

    fn mention(&self, node: &Value) -> Result<Node> {
        let display = string(node, "display").unwrap_or_default();
        if node["all"].as_bool() == Some(true) {
            return Ok(Node::Mention {
                target: MentionTarget::All,
                display,
            });
        }
        let identity = node["identity"]
            .as_i64()
            .ok_or_else(|| eyre!("a mention of no one"))?;
        Ok(if self.identities.contains_key(&IdentityId(identity)) {
            Node::Mention {
                target: MentionTarget::Identity(IdentityId(identity)),
                display,
            }
        } else {
            // Someone on a platform that stayed behind.
            Node::Text {
                text: format!("@{display}"),
            }
        })
    }
}

fn medium(node: &Value) -> Result<Node> {
    let kind: MediaKind = serde_json::from_value(node["kind"].clone())
        .map_err(|_| eyre!("media of kind {}", node["kind"]))?;
    let media = match string(node, "source") {
        None => None,
        Some(source) => Some(match source.strip_prefix("blob:") {
            Some(sha256) => MediaRef::Blob(sha256.to_owned()),
            None if source.starts_with("http://") || source.starts_with("https://") => {
                MediaRef::Remote(source)
            }
            None => bail!("media from {source:?}"),
        }),
    };
    Ok(Node::Media {
        media,
        meta: MediaMeta {
            kind,
            mime: string(node, "mime"),
            size: node["size"].as_u64(),
            name: string(node, "name"),
            description: string(node, "description").filter(|text| !text.trim().is_empty()),
        },
    })
}

/// A string, or a number written as one.
fn string(node: &Value, key: &str) -> Option<String> {
    match &node[key] {
        Value::String(text) => Some(text.clone()),
        Value::Number(number) => Some(number.to_string()),
        _ => None,
    }
}

/// Neighbouring texts as one.
fn joined(nodes: Vec<Node>) -> Vec<Node> {
    let mut out: Vec<Node> = Vec::with_capacity(nodes.len());
    for node in nodes {
        if let (Some(Node::Text { text: last }), Node::Text { text }) = (out.last_mut(), &node) {
            last.push_str(text);
            continue;
        }
        out.push(node);
    }
    out
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn people() -> BTreeMap<IdentityId, PrincipalId> {
        BTreeMap::from([(IdentityId(12), PrincipalId(2))])
    }

    fn text(text: &str) -> Node {
        Node::Text { text: text.into() }
    }

    #[test]
    fn nodes_one_by_one() {
        let children = HashMap::new();
        let people = people();
        let converter = Converter {
            children: &children,
            identities: &people,
        };
        let old = json!([
            {"type": "text", "text": "看 "},
            {"type": "mention", "display": "小明", "identity": 12},
            {"type": "text", "text": " "},
            {"type": "mention", "display": "Max", "identity": 15},
            {"type": "emote", "platform": "qq", "native_id": 14, "name": "微笑", "raw": {}},
            {"type": "media", "kind": "image", "source": "blob:ab", "mime": "image/png", "size": 3, "description": " "},
            {"type": "media", "kind": "sticker", "source": null},
            {"type": "card", "title": "标题", "url": "https://example.com", "preview": "blob:cd"},
            {"type": "media", "kind": "file", "source": "https://example.com/a.zip", "name": "a.zip"},
            {"type": "unsupported", "source": "qq:record", "description": "语音"},
        ]);
        let converted = converter.convert(7, old.as_array().unwrap()).unwrap();
        let image = MediaMeta {
            kind: MediaKind::Image,
            mime: Some("image/png".into()),
            size: Some(3),
            name: None,
            description: None,
        };
        let sticker = MediaMeta {
            kind: MediaKind::Sticker,
            mime: None,
            size: None,
            name: None,
            description: None,
        };
        let file = MediaMeta {
            kind: MediaKind::File,
            name: Some("a.zip".into()),
            ..sticker.clone()
        };
        assert_eq!(
            converted.nodes,
            [
                text("看 "),
                Node::Mention {
                    target: MentionTarget::Identity(IdentityId(12)),
                    display: "小明".into(),
                },
                text(" @Max"),
                Node::Emote(Emote {
                    platform: Platform::QqLegacy,
                    id: "14".into(),
                    name: Some("微笑".into()),
                }),
                Node::Media {
                    media: Some(MediaRef::Blob("ab".into())),
                    meta: image,
                },
                Node::Media {
                    media: None,
                    meta: sticker,
                },
                Node::Card(Card {
                    tag: None,
                    title: Some("标题".into()),
                    subtitle: None,
                    url: Some("https://example.com".into()),
                }),
                Node::Media {
                    media: Some(MediaRef::Remote("https://example.com/a.zip".into())),
                    meta: file,
                },
                Node::Unsupported(Unsupported {
                    source: "qq:record".into(),
                    description: "语音".into(),
                }),
            ]
        );
        // The old index counts every node; the ordinal only media.
        assert_eq!(converted.media, [((7, 5), 0), ((7, 6), 1), ((7, 8), 2)]);
    }

    #[test]
    fn forwards_fold_into_their_container() {
        let child = |id, name: &str, nodes: Value| Child {
            id,
            name: name.into(),
            nodes: nodes.as_array().unwrap().clone(),
        };
        let children = HashMap::from([
            (
                1,
                vec![
                    child(
                        2,
                        "甲",
                        json!([{"type": "text", "text": "第一句"}, {"type": "media", "kind": "image"}]),
                    ),
                    child(3, "乙", json!([{"type": "forward", "native_id": "F2"}])),
                ],
            ),
            (
                3,
                vec![child(4, "丙", json!([{"type": "media", "kind": "video"}]))],
            ),
        ]);
        let people = people();
        let converter = Converter {
            children: &children,
            identities: &people,
        };
        let old = json!([
            {"type": "media", "kind": "image"},
            {"type": "forward", "native_id": "F1"},
        ]);
        let converted = converter.convert(1, old.as_array().unwrap()).unwrap();
        let forward = |id: &str, count| {
            Node::Forward(ForwardRef {
                native_id: id.into(),
                count: Some(count),
            })
        };
        let medium = |kind| Node::Media {
            media: None,
            meta: MediaMeta {
                kind,
                mime: None,
                size: None,
                name: None,
                description: None,
            },
        };
        assert_eq!(
            converted.nodes,
            [
                medium(MediaKind::Image),
                forward("F1", 2),
                text("\n甲：第一句"),
                medium(MediaKind::Image),
                text("\n乙："),
                forward("F2", 1),
                text("\n  丙："),
                medium(MediaKind::Video),
                text("\n\n"),
            ]
        );
        assert_eq!(converted.media, [((1, 0), 0), ((2, 1), 1), ((4, 0), 2)]);
    }

    #[test]
    fn unknown_nodes_stop_the_import() {
        let children = HashMap::new();
        let people = people();
        let converter = Converter {
            children: &children,
            identities: &people,
        };
        let old = json!([{"type": "poke"}]);
        assert!(converter.convert(1, old.as_array().unwrap()).is_err());
        let old = json!([{"type": "media", "kind": "image", "source": "file:///a"}]);
        assert!(converter.convert(1, old.as_array().unwrap()).is_err());
    }
}
