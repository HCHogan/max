看网页和链接的用法：B站视频、知乎、通用隐身浏览器的流程与限制

# B站（view_bilibili）

url 接受完整链接、BV号、b23.tv 短链、[card:] 卡片里的链接。返回标题、UP主、简介、
时长、播放/点赞/投币/收藏、按赞数排的前 15 条热评。默认 with_video=true：整段视频
以 480p 附在下一条消息（占 1 个附件配额，仅多模态档位能看）——要聊画面内容就先
真的看一眼，别只凭标题和评论下结论。只关心数据或评论区风向时传 with_video=false
省流。480p 有 70MB 预算（约 30-35 分钟），超了附不上，自动退化为只有文本信息——
这不是失败，文本部分照常可用。

# 知乎（view_zhihu）

问题页、回答、专栏文章的链接直接传（[card:] 里的也行）。用群的隐身浏览器打开并
返回正文（截前 12000 字）；知乎首访有一道验证，工具会自动等 2.5s 重试（最多两
次），慢十几秒是正常的，重试用尽会明说、稍后再试即可。返回后页面保持打开：想看
更多回答/评论，接着用 browser_scroll 翻页、browser_snapshot 重新截取文本。

# 通用网页（browser_*）

browser_navigate 打开任意 URL。隐身浏览器每群一个、跨 dispatch 存活；会话闲置约
15 分钟会过期，另有请求数预算和不安全请求防护（触发会整个重置）——不管哪种，
后续工具都会明说"重新 navigate"，照做即可，不算错误。
交互循环：browser_snapshot 拿页面文本 + 可交互元素（每个带 CSS selector 和角色/
名字，默认最多 100 个元素，maxElements 可调，selector 参数可只截某个元素）→
browser_click / browser_type 用 selector 操作（click 完自带新 snapshot；type 是
替换整个输入框的值，submit=true 顺手回车）→ 页面变化后重新 snapshot，旧 snapshot
里的 selector 可能已失效。异步加载用 browser_wait_for 等元素状态（visible/
attached/…）或页面 load 状态（domcontentloaded/load/networkidle）；browser_scroll
默认下滚 600px、负数上滚、可指定滚动某个元素，滚完自带新 snapshot；
browser_press_key 按单键（Enter/ArrowDown/Escape…），可先聚焦某个 selector。
