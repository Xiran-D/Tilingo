class_name Taunt
extends RefCounted

# AI 台词引擎（2026-11-02，用户口令「离线生成、在线查表」）
# ===========================================================================
# 职责边界（刻意划死）：
#   本类**只做文本**——局面快照 / 玩家一句话 → 意图标签 → 从池子里挑一句 → 填槽位。
#   它**不认识 game.gd、不认识 UI、不认识任何 ai_engine**：
#     · 输入只是几个数或一个字符串（由 game.gd 从 `an_*` / 输入框抄来）；
#     · 输出只是一句 `String`（空串 = 不说话），谁去画、画在哪、多久全由调用方定。
#   ⇒ 理由同 `voice_chat.gd` 那条：将来换显示位置（聊天区 → HUD → 气泡）本文件零改动。
#
# ★★ 为什么是"查表"而不是本地小 LLM（2026-11-02 定论，别推翻）：
#   ① 0.5B 模型 Q4 约 397MB，而本工程导出包总共 390MB —— 包体直接翻倍；
#   ② 更要命的是 CPU：`tb200` vs `tb400` 32 局 16:16（z=0.00）已证明**算力饱和**，
#      LLM 一跑就抢走 MCTS 的线程预算 ⇒ AI 下棋变慢，是纯亏损；
#   ③ 生成式输出在 Steam 上不可控（玩家会试探 prompt）。
#   ⇒ 「生成」这一步搬到开发机离线做（大模型出候选 + 人工过一遍），运行期只做查表。
#
# ★★ 两条说话路径（2026-11-02 v2，用户口令「一般情况AI有问必答，但也可以不回应，
#    AI主动聊天只发生在居中出现妙手时」）：
#     ① `on_move()` —— **主动**。每落一手调一次，但**只在出现妙手时**才可能开口。
#        初版是"按局势分类（领先/落后/提子/屠龙）每 7 手点评一句"，被这条口令推翻：
#        那种点评在玩家眼里就是"AI 一直在念旁白"。现在唯一的主动触发是**妙手**。
#     ② `reply_to()` —— **被动**。玩家说一句，按关键词命中意图后回一句；
#        每个意图有自己的回复率 ⇒ "有问必答"（问题类 0.9）与"可以不回应"（兜底 0.45）并存。
#   ⇒ 两条路径共用同一个 `pool`，但**冷却与节流是分开的**：回话不该被落子冷却挡住。
#
# ★★ 统一一套模板（用户 2026-11-02 口令）：
#   池子只有 `ai/taunts.json` **一份**，所有对战 AI（ai_engine / liushui / yema）共用。
#   聊天层本来就在 game.gd，与"这一局是哪个引擎在下"无关 ⇒ 按引擎分池是**假需求**。
#
# ★★ 全部阈值都是普通 `var`（运行期可调），不写死在判定里 —— 用户长期口径
#   「所有参数要能在运行期实时调节」。它们是旋钮就有人读，不是死参数（§33）。
# ===========================================================================

## 池子路径。★ 落在 `ai/` 下是为了**白拿打包**：`export_presets.cfg` 里
## 已有 `include_filter="ai/*.json,audio/*.json"`，加文件不用改导出配置。
const POOL_PATH := "res://ai/taunts.json"

# ---- 运行期旋钮（全部有读者，别加没人读的）----
# ★ 总闸**不在这里**：它在 `game.gd` 的 `@export var taunt_enabled`（唯一真源）。
#   本类若再放一个 `enabled`，就成了一把拧不动的死旋钮 + 一个必然漂移的副本（§33）。
## 主动说话的最小冷却（手）。★ 妙手本来就稀疏，这个数只为挡"连续两手都被判成妙手"。
var cooldown_moves := 3
## 一句台词显示多久（秒）。由调用方读走用来起计时。
var life_sec := 4.0
## **妙手门槛**（目）。本手让 AI 目差变化 ≥ 它才算妙手。
## ★ 这是整套主动说话的唯一触发阈值，也是**唯一没实测过**的数（见 `--taunttest` 的说明）。
##   太小 ⇒ 每手都"妙手"（退回被推翻的旁白模式）；太大 ⇒ 一局说不上一句。
## ★★ 判据读的是 `an_ai_diff` 的**跨手差值**，所以这个数直接吃分析器的叶子噪声
##   （`#6/#7` 已证明叶子噪声是本工程的共同瓶颈）⇒ 上真机后第一件事是目检打印出来的 Δ。
var brilliant_delta := 8.0
## 回话节流（毫秒）。★ 连发短语时别把 AI 逼成复读机。
var reply_gap_ms := 400

# ---- 打字节奏（2026-11-03，用户口令「AI 对话回复的太快了，不像真人，
#      加一个停顿进去，按回复的字数设置停顿时间，模拟真人打字的速度」）----
## ★ 为什么不能只加一个**固定**延迟：真人一句话的耗时主要由**字数**决定 ——
##   "嗯。"和"这一步我想了很久，你这条龙其实早就没气了。"在同一套常数下不可能都像人。
##   固定延迟的两种死法：按短句调 ⇒ 长句像瞬移；按长句调 ⇒ 短句像在生气不理人。
## ★ 三段相加，缺任何一段都会露馅，理由各自不同：
##   ① `typing_pad_ms` —— **反应时间**：看到消息到手指动起来。与字数**无关**。
##      少了它，"嗯"会瞬回（真人不会）；它也解释得通"为什么刚才那句几乎立刻就有"。
##   ② `typing_per_char_ms × 字数` —— 主力项，就是"打字速度"本身。
##   ③ `typing_punct_ms × 标点数` —— 真人打完逗号/句号会顿一下（换气、想下一句）。
##      少了它，长句变成匀速流水线，观感像 TTS 朗读而不是有人在敲键盘。
## ★ `typing_max_ms` 是硬上限：长台词不许让玩家干等，也防以后有人写出 200 字台词。
## ★ 四个都是普通 `var`（运行期可调），默认值在 `ai/taunts.json` 的 `typing` 段。
var typing_pad_ms := 700
var typing_per_char_ms := 105
var typing_punct_ms := 180
var typing_max_ms := 4200

## 算"顿一下"的标点。★ 全角与半角都收：玩家/文案作者两种都会打。
const TYPING_PUNCT := "，。！？、；：…—·,.!?;:-"

# ---- 内部状态 ----
## 意图 -> Array[String]。载入后不再变。
var _pool: Dictionary = {}
## 每个意图上一次用到的下标：**只用来避免连续两次同一句**（池子长度 1 时不生效）。
var _last_idx: Dictionary = {}
## 关键词规则：`[{intent, words}]`，**顺序敏感**（先匹配的赢）。
var _chat_rules: Array = []
## 意图 -> 回复率。查不到就用 `_reply_default`。
var _reply_rate: Dictionary = {}
var _reply_default := 0.75
## 上一手的快照，`on_move()` 用它算 delta。`reset()` 清空。
var _prev: Dictionary = {}
## 冷却剩余手数 / 上次回话时刻。
var _cool_left := 0
var _reply_last_ms := 0
var _rng := RandomNumberGenerator.new()
## 探针：上一次 `on_move()` / `reply_to()` 命中的意图（空串 = 没命中）。
## ★ 判据要能分开"该说话但没说（冷却/概率）"和"这一步根本不是妙手"——
##   只看返回的句子，这两种情况都表现为空串，红起来无从归因。
var last_intent := ""
## 载入结果。false ⇒ 所有说话路径返回空串（**不报错、不说话**，
## 但 `load_error` 留着原因，自测与日志都读它 —— 静默失败是这条路的默认失败态）。
var loaded := false
var load_error := ""


func _init() -> void:
	_rng.randomize()


## 载入池子。返回是否成功（失败原因在 `load_error`）。
## ★ 路径不存在 / JSON 坏 / `pool` 段为空 / `chat_rules` 为空，**都算失败**：宁可整局不说话，
##   也不要半载入 —— 那种"有时说有时不说"在玩家眼里就是 bug，而在日志里什么都查不到。
func load_pool(path: String = POOL_PATH) -> bool:
	loaded = false
	load_error = ""
	_pool.clear()
	_last_idx.clear()
	_chat_rules.clear()
	_reply_rate.clear()
	if not FileAccess.file_exists(path):
		load_error = "找不到池子文件：%s" % path
		return false
	var txt := FileAccess.get_file_as_string(path)
	if txt == "":
		load_error = "池子文件为空或读不出来：%s" % path
		return false
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		load_error = "JSON 解析失败（不是字典）：%s" % path
		return false
	var root: Dictionary = parsed
	if int(root.get("version", 0)) < 2:
		load_error = "池子 version < 2（本版口径已变）：%s" % path
		return false
	# ---- 旋钮：JSON 给默认值（改文案的人也在改节奏）----
	cooldown_moves = int(root.get("cooldown_moves", cooldown_moves))
	life_sec = float(root.get("life_sec", life_sec))
	brilliant_delta = float(root.get("brilliant_delta", brilliant_delta))
	reply_gap_ms = int(root.get("reply_gap_ms", reply_gap_ms))
	# ---- 打字节奏 ----
	# ★ 整段缺失 ⇒ 保留类里的默认值（不是崩、也不是变 0）：老池子照样能跑，
	#   只是节奏用默认的。做成"缺就 0"会让升级前的池子瞬间变成"回话瞬发"，
	#   那正好是这次要修的病。
	var ty: Variant = root.get("typing", null)
	if typeof(ty) == TYPE_DICTIONARY:
		var tyd: Dictionary = ty
		typing_pad_ms = int(tyd.get("pad_ms", typing_pad_ms))
		typing_per_char_ms = int(tyd.get("per_char_ms", typing_per_char_ms))
		typing_punct_ms = int(tyd.get("punct_ms", typing_punct_ms))
		typing_max_ms = int(tyd.get("max_ms", typing_max_ms))
	# ---- 回复率 ----
	var rr: Variant = root.get("reply_rate", null)
	if typeof(rr) == TYPE_DICTIONARY:
		var rrd: Dictionary = rr
		_reply_default = float(rrd.get("default", _reply_default))
		for k in rrd.keys():
			if str(k) != "default":
				_reply_rate[str(k)] = float(rrd[k])
	# ---- 关键词规则 ----
	var cr: Variant = root.get("chat_rules", null)
	if typeof(cr) != TYPE_ARRAY:
		load_error = "池子缺少 chat_rules 段：%s" % path
		return false
	for rule in (cr as Array):
		if typeof(rule) != TYPE_DICTIONARY:
			continue
		var rd: Dictionary = rule
		var intent := str(rd.get("intent", ""))
		var raw_words: Variant = rd.get("words", null)
		if intent == "" or typeof(raw_words) != TYPE_ARRAY:
			continue
		var words: Array[String] = []
		for w in (raw_words as Array):
			var s := str(w).strip_edges().to_lower()
			if s != "":
				words.append(s)
		if not words.is_empty():
			_chat_rules.append({"intent": intent, "words": words})
	if _chat_rules.is_empty():
		load_error = "chat_rules 段里没有任何可用规则：%s" % path
		return false
	# ---- 池子本体 ----
	var raw: Variant = root.get("pool", null)
	if typeof(raw) != TYPE_DICTIONARY:
		load_error = "池子缺少 pool 段：%s" % path
		return false
	var pool_d: Dictionary = raw
	var n_intent := 0
	for k in pool_d.keys():
		# ★ JSON 数组是未类型化的 `Array`，元素也未必是 String ⇒ 逐项转，
		#   直接赋给 `Array[String]` 会在运行期报类型错（而且是在第一句台词那一刻才炸）。
		var src: Variant = pool_d[k]
		if typeof(src) != TYPE_ARRAY:
			continue
		var lines: Array[String] = []
		for s in (src as Array):
			var line := str(s).strip_edges()
			if line != "":
				lines.append(line)
		if lines.is_empty():
			continue
		_pool[str(k)] = lines
		n_intent += 1
	if n_intent == 0:
		load_error = "pool 段里没有任何可用意图：%s" % path
		return false
	loaded = true
	return true


## 新开一局前调：清 delta 基准、冷却、回话节流、探针。**不重载池子**（池子是只读数据）。
## ★ 不调它的后果：跨局的 `_prev` 还在 ⇒ 第二局第一手会算出虚假的 delta
##   （上一局结束时 AI 目差 +40，这局开局第一手就报"妙手"）。
func reset() -> void:
	_prev.clear()
	_cool_left = 0
	_reply_last_ms = 0
	last_intent = ""


## 从两份快照算出**派生态**。纯函数：不读不写任何成员。
##
## `ctx` / `before` 都只认这几个键（多余的键忽略，缺的取默认）：
##   `ply` 手数 · `ai_diff` AI 目数差（正=AI 领先，无界）
##   `ai_dead` / `player_dead` 各自死块数 · `black_prisoners` / `white_prisoners` 提子桶
##   `mover_is_ai` 本手是不是 AI 落的 · `empties` 剩余空点 · `total_tiles` 总格数
##
## ★ 为什么是 `mover_is_ai`（布尔）而不是 `mover`（颜色值）：
##   本工程 `enum Stone { EMPTY, BLACK, WHITE }` ⇒ **黑=1 白=2**，不是 0/1。
##   第一版按 `mover == 0 / == 1` 挑提子桶，`--taunttest` ⑤ 当场红。根子不是"写错一个常数"，
##   而是**本文件不该认识 `Stone` 的数值**——那是跨文件的隐式契约，改枚举顺序就静默失效。
##   ⇒ 颜色换算留在 `game.gd`（它本来就认识 Stone），这里只收语义。
func derive(ctx: Dictionary, before: Dictionary) -> Dictionary:
	var mover_is_ai := bool(ctx.get("mover_is_ai", false))
	var ai_dead_delta := int(ctx.get("ai_dead", 0)) - int(before.get("ai_dead", 0))
	var player_dead_delta := int(ctx.get("player_dead", 0)) - int(before.get("player_dead", 0))
	# 本手提子数 = **两个桶的增量之和**。
	# ★ 一手里只有一个桶会动（提子只记落子方，见 `black_prisoners` 的归属口径），
	#   所以"和"就是本手提子数 —— 且这个算法对 Stone 的数值、对谁执什么色全都无假设。
	var d_black := int(ctx.get("black_prisoners", 0)) - int(before.get("black_prisoners", 0))
	var d_white := int(ctx.get("white_prisoners", 0)) - int(before.get("white_prisoners", 0))
	var cap_delta := d_black + d_white
	var ai_diff := float(ctx.get("ai_diff", 0.0))
	var diff_delta := ai_diff - float(before.get("ai_diff", ai_diff))
	var empties := int(ctx.get("empties", 0))
	var total := int(ctx.get("total_tiles", 0))
	var empty_frac := 0.0
	if total > 0:
		empty_frac = float(empties) / float(total)
	return {
		"ply": int(ctx.get("ply", 0)),
		"mover_is_ai": mover_is_ai,
		"ai_diff": ai_diff,
		"diff_delta": diff_delta,
		"diff_abs": absi(int(round(ai_diff))),
		# 本手目数变化的绝对值。台词槽位 `{delta}` 读它。
		# ★ 与 `diff_abs`（**总**目差）分开两个键：拿总目差填"这一手值 X 目"是错的语义
		#   （领先 45 目时任何一手都会被写成"值 45 目"），而且错得很像对。
		"delta_abs": absi(int(round(diff_delta))),
		# ★★ 「有没有基准」必须显式传下去（2026-11-02 自测逮到）：
		#   `before` 缺键时下面的 `before.get(k, 0)` 一律取 0，而实际值可能非 0
		#   ⇒ **凭空算出一个从没发生过的巨大 delta**。真实症状：新局第一手（`_prev` 刚被
		#   `reset()` 清空）若是从棋谱载入的中盘，`ai_diff` 本来就是 -30 ⇒ 开局第一句就是"妙手"。
		#   所以一切 Δ 类判据都必须挂 `has_prev` 闸。
		"has_prev": not before.is_empty(),
		"ai_dead_delta": ai_dead_delta,
		"player_dead_delta": player_dead_delta,
		"cap_delta": cap_delta,
		"empty_frac": empty_frac,
	}


## 派生态 → **主动**说话的意图。纯函数。返回空串 = 这一手不该开口。
##
## ★★ 2026-11-02 v2：这里的判据只剩"妙手"一条，这是用户明确要求
##   （「AI 主动聊天只发生在居中出现妙手时」）。初版那套按局势分类的点评
##   （领先 / 落后 / 屠龙 / 大提子 / 收官）**已全部删除** —— 它们不是被阈值调掉的，
##   而是"要不要主动点评局势"这个产品决定本身被推翻了。想恢复必须重新走一次用户口令，
##   别因为"代码里还留着分支"就顺手打开。
##
## 妙手的判定 = **AI 目差的跨手变化**（`an_ai_diff` 的差值）：
##   · 玩家落子让 AI 目差**掉得够多**（≤ -brilliant_delta）⇒ 玩家妙手 ⇒ `brilliant_opp`
##   · AI 落子让 AI 目差**涨得够多**（≥ +brilliant_delta）⇒ AI 妙手   ⇒ `brilliant_self`
## ★ 为什么不用"引擎对单点的评分差"（`probe_root_score_last()` 那条路）：那要每手
##   额外跑两次根节点评估，而本工程已证明算力饱和（`tb200` vs `tb400` = 16:16）。
##   用 `an_ai_diff` 的差值**零额外成本**（`_refresh_analyze()` 每手本来就在跑）。
##   代价是精度：分析器有叶子噪声，误判一定会有 —— 所以 `brilliant_delta` 是可调旋钮，
##   而且要配合冷却（`cooldown_moves`）用。
func classify(d: Dictionary) -> String:
	# 没有上一手就没有 delta 可言（见 `derive()` 里 `has_prev` 那条注释）。
	if not bool(d.get("has_prev", false)):
		return ""
	var dd := float(d.get("diff_delta", 0.0))
	# ★ 比较方向必须在**每一侧各写一条**，不共用一个 sign（§17）：
	#   这里"好事"对 AI 与对玩家是**相反的符号**，共用 `absf()` 会把恶手也判成妙手。
	if bool(d.get("mover_is_ai", false)):
		if dd >= brilliant_delta:
			return "brilliant_self"
	else:
		if dd <= -brilliant_delta:
			return "brilliant_opp"
	return ""


## 从某个意图里挑一句并填槽位。返回空串 = 该意图没有台词（或池子没这个键）。
## ★ 池子里没有该键**不算错误**：想做减法时删掉一整段即可，代码不用动
##   （删空的那一类就自动沉默，这正是"统一一套模板"该有的可编辑性）。
func pick(intent: String, d: Dictionary) -> String:
	if intent == "":
		return ""
	var raw: Variant = _pool.get(intent, null)
	if typeof(raw) != TYPE_ARRAY:
		return ""
	var arr: Array = raw
	if arr.is_empty():
		return ""
	var i := _rng.randi_range(0, arr.size() - 1)
	# 避免连续两次同一句：池子只有一条时无从避，也就不避
	if arr.size() > 1 and int(_last_idx.get(intent, -1)) == i:
		i = (i + 1) % arr.size()
	_last_idx[intent] = i
	return _fill(str(arr[i]), d)


## 槽位填充。目前两个：`{delta}` 本手目数变化（取绝对值 —— 语气由意图标签承担方向）、
## `{diff}` 总目差（同样取绝对值）。
## ★ 这两个槽位很少用到（10 类台词里只有 2 条），但**留着**：它们是"让同一句台词在不同局面
##   下读起来不一样"的唯一手段，而池子是给非程序员改的 —— 删掉之后想加就没路可走了。
func _fill(s: String, d: Dictionary) -> String:
	if not s.contains("{"):
		return s
	var out := s
	out = out.replace("{delta}", str(int(d.get("delta_abs", 0))))
	out = out.replace("{diff}", str(int(d.get("diff_abs", 0))))
	return out


## **主动说话的唯一入口**：吃一手之后的局面快照，返回要说的话（空串 = 不说）。
##
## 调用方每落一手调一次。内部顺序固定：
##   算 delta → 分类 → 冷却 → 选句 → 推进基准
## ★ 基准必须**无条件**推进（包括不是妙手、冷却中、池子没这一类）：
##   只在"说了话"时才推进的话，delta 会跨好几手累积，最后把普通几手攒成一次假妙手。
func on_move(ctx: Dictionary) -> String:
	last_intent = ""
	if not loaded:
		return ""
	var d := derive(ctx, _prev)
	var intent := classify(d)
	last_intent = intent
	var out := ""
	# ★ 冷却只拦"说话"，不拦基准推进。
	#   递减放在分类之后，这样"这一手本来是妙手但还在冷却"也确实消耗了一次机会，
	#   否则一旦进入冷却就永远停在原地（_cool_left 不减 ⇒ 冷到天荒地老）。
	if _cool_left > 0:
		_cool_left -= 1
	else:
		out = pick(intent, d)
		if out != "":
			_cool_left = maxi(cooldown_moves, 1)
	_prev = ctx.duplicate()
	return out


## **被动回话的唯一入口**：玩家说了一句，返回 AI 的话（空串 = 这次不回应）。
##
## ★ "有问必答，但也可以不回应"（用户 2026-11-02 口令）就是 `reply_rate` 那张表：
##   问题类 0.9（基本必答）、兜底 0.45（常常装没听见）、其余默认 0.75。
##   概率是**逐次**掷的，所以同一句话连问两次也可能一次答一次不答 —— 这是刻意的：
##   固定"有问必答"会让 AI 变成问答机器，而"有时不回"才是活人的手感。
##
## ★ 节流 `reply_gap_ms` 与落子冷却 `_cool_left` **分开**：回话不该被落子冷却挡住，
##   否则玩家说话时 AI 可能因为"刚点评过一句"而装死（玩家会以为它坏了）。
func reply_to(text: String) -> String:
	last_intent = ""
	if not loaded:
		return ""
	var t := text.strip_edges()
	if t == "":
		return ""
	var now := Time.get_ticks_msec()
	if _reply_last_ms > 0 and now - _reply_last_ms < reply_gap_ms:
		return ""
	var intent := match_chat_intent(t)
	last_intent = intent
	var rate := reply_rate_for(intent)
	if _rng.randf() > rate:
		return ""
	var out := pick(intent, {})
	if out == "":
		return ""
	_reply_last_ms = now
	return out


## 一句话"打出来"要多久（**毫秒**）。纯函数：不读也不写任何成员，不碰场景树、不起计时器。
##
## 公式 = `pad(反应) + 字数 × per_char + 标点数 × punct`，再夹到 `[0, max]`。
##
## ★ 为什么放在 `taunt.gd` 而不是 `game.gd`：节奏是**内容属性**（只跟字数与标点有关），
##   与"哪台机器、什么分辨率、抽屉开没开"全都无关。放这里就能被自检当**纯函数**量，
##   不需要 `await`、不需要等帧 —— 而带动画的判据只能断函数关系、断不了绝对值（§134）。
## ★ 返回 0 表示"不用等"（空串、或 `max_ms` 被拧成 0）。调用方据此走同步路径，
##   所以"关掉停顿"不需要第二个开关。
func typing_ms_for(line: String) -> int:
	var t := line.strip_edges()
	if t == "":
		return 0
	var n := t.length()
	var np := 0
	for i in n:
		if TYPING_PUNCT.contains(t[i]):
			np += 1
	var ms := float(typing_pad_ms) + float(n) * float(typing_per_char_ms) \
		+ float(np) * float(typing_punct_ms)
	var hi := maxf(0.0, float(typing_max_ms))
	return int(round(clampf(ms, 0.0, hi)))


## 玩家一句话 → 意图。按 `chat_rules` 的**顺序**匹配（先命中的赢，见 JSON 里的排序理由）。
## 都不中 ⇒ `chat_other`（兜底；它的回复率最低，所以很多话会被"嗯"掉或者干脆不回）。
func match_chat_intent(text: String) -> String:
	var low := text.to_lower()
	for rule in _chat_rules:
		var rd: Dictionary = rule
		for w in (rd.get("words", []) as Array):
			if low.contains(str(w)):
				return str(rd.get("intent", "chat_other"))
	return "chat_other"


## 某个意图的回复率（0..1）。查不到就用 `default`。
func reply_rate_for(intent: String) -> float:
	if _reply_rate.has(intent):
		return clampf(float(_reply_rate[intent]), 0.0, 1.0)
	return clampf(_reply_default, 0.0, 1.0)


## 池子里的意图键（排序后）。自测与"文案漏了哪类"的排查用。
func intents() -> Array[String]:
	var out: Array[String] = []
	for k in _pool.keys():
		out.append(str(k))
	out.sort()
	return out


## `chat_rules` 里被引用到的意图（去重排序）。判据用它查"规则指向的意图有没有台词"。
func rule_intents() -> Array[String]:
	var seen: Dictionary = {}
	for rule in _chat_rules:
		seen[str((rule as Dictionary).get("intent", ""))] = true
	var out: Array[String] = []
	for k in seen.keys():
		out.append(str(k))
	out.sort()
	return out


## 台词总条数（所有意图加起来）。自测用它确认池子真的读进来了。
func line_count() -> int:
	var n := 0
	for k in _pool.keys():
		n += (_pool[k] as Array).size()
	return n
