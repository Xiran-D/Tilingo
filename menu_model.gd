class_name MenuModel
extends RefCounted
## 两个菜单共用的**唯一数据层**（桌面密铺菜单 `menu.gd` / 手机菜单 `menu_mobile.gd`）。
##
## ★ 为什么要有这一层（用户 2026-09-23 决定「重写一个 iOS 菜单」时明确要求"抽出共享数据层"）：
##   本项目反复踩过同一个坑 —— **同一件事在两套互不相干的代码里各写一遍，然后同样的 bug 修两遍**：
##     · 两套 ESC 面板配色（`game.gd` 暂停 / `menu.gd` 退出确认）各写一套 → 字色错两回；
##     · `--esctest` 两侧都有判据，但回归清单里只有菜单侧 → 对局侧那条**没有 runner**。
##   菜单里最贵的一次是 2026-09-19 那个 bug：二级行的**标签 / 选中态 / 回调**三处各判一次
##   "这行是大小三档还是种类三档"，结果先建行再切棋盘时，标签换了、回调没换 →
##   「点种类毫无反应」+「其他棋盘的标准/加强被改名」，而且**静默**。
##   那次是把三处统一到 `_is_hat_eff()` 一个判据才修好的（铁律 7）。
##   现在要再加一个菜单 —— 如果两个菜单各写一套槽位语义，那次 bug 会**成对复活**。
##   → 所以「槽位语义 / 选项清单 / 有效选择 / 写 GameConfig」全部收到这里，两个菜单只负责"画"。
##
## ★ 设计口径（刻意选的，别再改回去）：
##   · **纯静态函数**，不持有状态、不引用任何节点。状态仍留在各菜单自己身上
##     （`menu.gd` 有 5000 行、`_sel_board` 被 100+ 处引用，搬状态是高风险无收益的动作；
##      搬"判据"才是真正在消灭分叉）。
##   · 需要状态的函数一律**显式传参**（`hat_eff` / `sel_size` / `sel_hatkind`）——
##     这样"标签用哪个判据、选中态用哪个判据"在**调用点**一眼可见，不可能悄悄各判一套。
##   · 只有一个函数**写** `GameConfig`（`apply_choice_to_config`），与铁律 8「一处写、一处读」一致。

# ---------------- 选项清单（唯一真源） ----------------

## 棋盘清单 = **练习菜单「棋盘」下拉列表的选项**（8 项 = 3 张盘 × 固定/随机 + 筝形 + 爱因斯坦）。
##
## ★★ 2026-11-06 用户口令改口径两次，最终形态（**改回这两句之前的版本前先读这段**）：
##   原口令 A「再加一个可以选的随机棋盘」→ 曾做成棋盘行第六块「随机」= 抽一张盘型（别名）。
##   原口令 B「把棋盘和该棋盘的随机模式拆成两个棋盘选项，比如彭罗斯和彭罗斯随机，
##     然后选项太多了，就改成下拉列表选择」⇒ **别名整族删除**，改成「盘型 × 随机形状」两根轴：
##     `random=true` 的项 = 同一格数档下每局现场生成一张**形状不同**的盘
##     （`GameConfig.board_random_shape`），格数仍由小/中/大三档决定。
##   ★ 为什么不是"随机档 ≈200 格"：用户明确选了「仍吃大小三档（随机只换形状）」——
##     格数决定对局时长这条口径必须保住，随机只换形状。
##   ★ **筝形没有随机项**：它的生成器按正六边形环数取样，没有"随机形状"实现
##     （`game.gd::_is_random_board()` 明确排除它）。用户裁决：下拉里不出「筝形随机」。
##     将来要做，得新写生成器 + 连通性/邻接/星位判据，别只在这里加一行。
##   ★ **爱因斯坦也没有随机项**（2026-11-07 用户口令「爱因斯坦盘本身就使用随机的，
##     何必再加随机？」）：帽子家族是非周期单瓦片密铺，盘面本来就由池 + BFS 现场长出，
##     再挂一个「形状随机」在玩家眼里就是重复选项 ⇒ 下拉里只留「爱因斯坦」一项。
##     ⚠️ 改的是**菜单口径**，不是生成器：`board_random_shape` 对 HAT 仍可经 CLI /
##     旧棋谱 / AI 仪器置真（旧 RANDOM 档与 `hat_rand_tiles` 窗口都要复现），别动 `generate_hat()`。
##
## ★ 键：`label`（下拉里显示）/ `id`（`GameConfig.BOARD_*`）/ `random`（形状是否随机）。
##   占位项（`敬请期待`）**整族删除**：它们是给旧的"横排循环行"拉长周期用的，
##   下拉列表里没有循环周期问题，留着只是两条点不动的选项。
const BOARD_KINDS: Array = [
	{"label": "彭罗斯", "id": GameConfig.BOARD_PENROSE, "random": false},
	{"label": "彭罗斯随机", "id": GameConfig.BOARD_PENROSE, "random": true},
	{"label": "立方体", "id": GameConfig.BOARD_CUBE, "random": false},
	{"label": "立方体随机", "id": GameConfig.BOARD_CUBE, "random": true},
	{"label": "筝形", "id": GameConfig.BOARD_KITE, "random": false},
	{"label": "雪花", "id": GameConfig.BOARD_SNOWFLAKE, "random": false},
	{"label": "雪花随机", "id": GameConfig.BOARD_SNOWFLAKE, "random": true},
	{"label": "爱因斯坦", "id": GameConfig.BOARD_HAT, "random": false},
]

## 爱因斯坦的三种瓦片（换的是**瓦片边长** → 直接决定盘面，所以和种子一样属于「盘面参数」，
## 开局时要跟棋盘类型一起推给 GameConfig、也要一起落盘）。
const HAT_KINDS: Array = [
	{"label": "帽子", "id": GameConfig.HAT_HAT},
	{"label": "海龟", "id": GameConfig.HAT_TURTLE},
	{"label": "幽灵", "id": GameConfig.HAT_SPECTRE},
]

## 二级行的"含义"枚举：同一组 3 个槽位承载两种含义。
## ★ 这就是 2026-09-19 那个 bug 的正主 —— 含义必须由**一个判据**现判，标签/选中态/回调共用。
const MEAN_SIZE: int = 0      # 棋盘大小三档（随机/标准/加强；筝形是迷你）
const MEAN_HAT_KIND: int = 1  # 爱因斯坦瓦片种类（帽子/海龟/幽灵）

const SLOT_HAT_FALLBACK: String = "帽子"

# ---------------- 清单查询 ----------------

## 棋盘选项清单（= 下拉列表的选项，顺序即显示顺序）。**唯一真源是 `BOARD_KINDS`**。
## ★ 2026-11-06：占位项已整族删除 ⇒ 本函数现在就是"原样返回"，
##   留着它是因为调用点很多（菜单建下拉 / `--labeltest` 花名册 / 联机选盘 / 格数档表），
##   将来若要再筛（例如按模式只出一部分盘）只有一个地方要改。
static func board_options() -> Array:
	return BOARD_KINDS


## 棋盘 id → **基准名**（不含"随机"后缀）。联机选盘、棋谱列表、日志都用它。
## ★ 多数 id 对应两个选项（固定/随机），筝形 / 爱因斯坦只有一个 ⇒ **别拿本函数当"当前选项名"**，
##   要显示当前选项请用 `board_option_label(id, random)`。
static func board_label(id: int) -> String:
	for k in BOARD_KINDS:
		if int(k["id"]) == id and not bool(k["random"]):
			return str(k["label"])
	# 只有随机项时才可能走到这里（例如将来某张盘只有随机版）
	for k in BOARD_KINDS:
		if int(k["id"]) == id:
			return str(k["label"])
	return ""


## 当前选项的显示名（带「随机」后缀）——下拉列表、页首摘要用它。
static func board_option_label(id: int, random: bool) -> String:
	for k in BOARD_KINDS:
		if int(k["id"]) == id and bool(k["random"]) == random:
			return str(k["label"])
	return board_label(id)


## 选项在清单里的下标（`OptionButton.selected` 只能按下标）。
## 找不到时退回 0（= 第一项，固定彭罗斯）——**绝不返回 -1**：那会让下拉停在"未选"。
static func board_option_index(id: int, random: bool) -> int:
	for i in BOARD_KINDS.size():
		var k: Dictionary = BOARD_KINDS[i]
		if int(k["id"]) == id and bool(k["random"]) == random:
			return i
	return 0


## 下标 → `{board, random}`（下拉 `item_selected` 的回调用它）。
## 越界退回选项 0（同上：连崩都不许）。
static func board_option_at(index: int) -> Dictionary:
	if index < 0 or index >= BOARD_KINDS.size():
		index = 0
	var k: Dictionary = BOARD_KINDS[index]
	return {"board": int(k["id"]), "random": bool(k["random"])}


## **真盘型 id** 清单（去重：8 个选项 → 5 个 id，筝形 / 爱因斯坦只有固定版）。
## ★ 消费方：格数档表 `SIZE_TIERS`（每张盘一条，不是每个选项一条）、联机代抽、谱头统计。
##   拿选项清单去做这些事会把同一张盘数两遍（彭罗斯 5 档变 10 档，判据分母翻倍）。
static func board_ids() -> Array:
	var out: Array = []
	for k in BOARD_KINDS:
		var id: int = int(k["id"])
		if not out.has(id):
			out.append(id)
	return out


## 该棋盘 id 是不是**当前启用**项。旧配置里的 id 可能指向已下线的盘（经典 19×19 于 2026-09-15
## 下线、随机盘型别名 6 于 2026-11-06 下线），编号不复用 ⇒ 恢复上一局时靠它整份作废，
## 绝不能去画一个不存在的选项。
static func board_id_valid(id: int) -> bool:
	return board_ids().has(id)


## 该盘有没有随机形状版（筝形没有 —— 生成器不支持；爱因斯坦没有 —— 盘本身已是非周期，
##   见 `BOARD_KINDS` 那段 11-07 的两条裁决）。
static func board_has_random(id: int) -> bool:
	for k in BOARD_KINDS:
		if int(k["id"]) == id and bool(k["random"]):
			return true
	return false


## 该棋盘是不是走「种类」语义（= 爱因斯坦）
static func is_hat_board(board: int) -> bool:
	return board == GameConfig.BOARD_HAT


## ★★ 2026-11-06 拆成两套槽位表（原来是**一个** `slots()` 同时被两种语义用）：
##   以前尺寸档恰好是 RANDOM(0)/STANDARD(1)/ENHANCED(2)，而帽子种类恰好是 0/1/2
##   ⇒ 同一个数组"碰巧"两种语义都对。三档改成 9×9/13×13/19×19 之后，小档是 `SMALL=3`，
##   再共用就会让**种类**被当成 3/1/2 去查表（第三个种类查不到 → 标签变「?」）。
##   ⇒ 「索引即契约」这一族坑的第二次兑现：**语义不同就必须两张表**。
static func size_slots() -> Array:
	return [GameConfig.SMALL, GameConfig.STANDARD, GameConfig.ENHANCED]


## 帽子种类的三个槽位号（顺序即显示顺序）。真源 = `HAT_KINDS`，不另抄一份数字。
static func hat_slots() -> Array:
	var out: Array = []
	for k in HAT_KINDS:
		out.append(int(k["id"]))
	return out


## 第 slot 个槽位号 —— **按当前含义**取（尺寸档 or 帽子种类）。调用点必须显式传 `hat_eff`，
## 这样"这行是三档尺寸还是三种类"在调用点一眼可见（本文件一贯口径）。
static func slots(hat_eff: bool = false) -> Array:
	return hat_slots() if hat_eff else size_slots()


## 种类 id → 显示名（查不到退回「帽子」，**绝不返回空串** —— 空串会把瓷砖标签清掉）
static func hat_kind_label(id: int) -> String:
	for k in HAT_KINDS:
		if int(k["id"]) == id:
			return str(k["label"])
	return SLOT_HAT_FALLBACK


# ---------------- 槽位语义（标签 / 选中态 / 回调三者的**共同**来源） ----------------

## 第 slot 个槽位此刻是什么含义。★ 这是判据本身，不是"再判一遍"。
static func slot_meaning(hat_eff: bool) -> int:
	return MEAN_HAT_KIND if hat_eff else MEAN_SIZE


## 纯大小档名（不含爱因斯坦分支；手机菜单的「大小」行单独显示用）
## 尺寸档 → 显示名。★★ 2026-11-06 改口径（用户口令「统一所有棋盘格数，全部对标常规棋盘的
##   9*9 13*13 19*19」）：三档现在是 **9×9 / 13×13 / 19×19**，不再是「随机/标准/加强」。
##   ★ "随机"已从尺寸栏移出（改成棋盘栏里的独立盘型 `BOARD_RANDOM`）⇒ 这里不再产出它。
##   ★ 各盘在三档下的**实际**格数略有差异（环数/层数是整数：立方体 57/183/381、
##     筝形 72/162/288、雪花 72/144/408 …）—— 标签表达的是"对标哪张常规盘"，
##     精确格数由 game.gd 的档位表负责，别在标签里写死格数（否则五张盘要五套标签）。
static func size_label(slot: int, _board: int) -> String:
	match slot:
		GameConfig.SMALL:
			return "9×9"
		GameConfig.STANDARD:
			return "13×13"
		GameConfig.ENHANCED:
			return "19×19"
		GameConfig.RANDOM:
			return "随机（旧）"      # 只会在读旧棋谱/旧配置时出现
	return "?"


## 第 slot 个槽位在当前「有效选中棋盘」下的显示名。
## ★ 唯一真源：建项、切棋盘后改写、手机菜单的选项块 —— 都调它。
##   传 `hat_eff` 而不是让函数自己去问某个菜单的状态：这样"标签用哪套语义"在调用点可见。
static func slot_label(slot: int, hat_eff: bool, board: int) -> String:
	if hat_eff:
		return hat_kind_label(slot)
	return size_label(slot, board)


## 第 slot 个槽位的选中态。与 `slot_label` **共用同一个 `hat_eff` 判据**，
## 保证「黑砖」与「标签」永远指同一件事。
static func slot_selected(slot: int, hat_eff: bool, sel_size: int, sel_hatkind: int) -> bool:
	return sel_hatkind == slot if hat_eff else sel_size == slot


## 点击第 slot 个槽位后**应当**落到哪一套状态上：返回 `{"size": n}` 或 `{"hat_kind": n}`。
## ★ 这就是「回调」那一条腿 —— 含义在**点击那一刻**由 `hat_eff` 现判，于是回调与标签结构上
##   不可能打架（2026-09-19 的修复要点）。两个菜单都该用它来决定写哪个状态字段。
static func slot_activation(slot: int, hat_eff: bool) -> Dictionary:
	return {"hat_kind": slot} if hat_eff else {"size": slot}


# ---------------- 有效选择 / 写入 GameConfig ----------------

## 开局与预览**共用的**「有效选择」三元组 `{board, size, hat_kind}`。
## ★ 这是「爱因斯坦一律走随机档」这条规则的**唯一落点**。
##   分头各写一遍就会出现「预览画的是标准盘、点开始却是随机盘」这种鬼状态
##   （本项目在完全同型的地方踩过）。手机菜单的「大小」行在帽子盘下要显示"由棋盘决定"，
##   也必须读这里，不能自己判 `board == HAT`。
## ★★ 2026-11-06：**删掉「爱因斯坦一律走随机档」那条规则**。
##   改前它是刚需（帽子盘的大小由种类决定、三种类都走随机档）；现在三档统一成
##   9×9/13×13/19×19 且随机档已从尺寸栏移出 ⇒ 帽子盘也吃三档（小 ~81 / 中 ~170 / 大 ~360），
##   种类只决定瓦片边长（换的是 `hat_kind`），与格数档正交。
## ★★ 2026-11-06：多了第四根轴 `random`（棋盘「XX随机」= 形状随机，格数照档）。
##   它必须和 board/size 一起从**同一处**产出 —— 分头各判一次就会出现
##   「下拉显示彭罗斯随机、开局却是固定盘」这种鬼状态（本工程在完全同型的地方踩过三次）。
static func effective_choice(board: int, sel_size: int, sel_hatkind: int,
		random: bool = false) -> Dictionary:
	var b: int = board
	if b < 0:
		b = GameConfig.BOARD_PENROSE
	# ★ 该盘没有随机版（筝形 / 爱因斯坦）时**强制回落固定**：`BOARD_KINDS` 里没有那一项，
	#   任何来源（旧配置、手改文件、将来别的菜单）传来 true 都必须被吃掉 ——
	#   否则要么走到一个**不存在随机生成器**的分支（筝形），要么让菜单去选一个
	#   已经下线的「爱因斯坦随机」下标（11-07 删），盘面/UI 描述静默不一致。
	var rs: bool = random and board_has_random(b)
	return {
		"board": b,
		"size": sel_size,
		"hat_kind": sel_hatkind,
		"random": rs,
	}


## **唯一**把选项写进 `GameConfig` 的地方（铁律 8）。`ch` 来自 `effective_choice()`。
## ⚠️ 只管这 3 个字段：「落盘上一局」（`save_last_match`）带难度/对战方式、还带"自动化运行不落盘"
##    的判断，那是菜单自己的事，别塞进来。
static func apply_choice_to_config(ch: Dictionary) -> void:
	GameConfig.board_type = int(ch.get("board", GameConfig.BOARD_PENROSE))
	GameConfig.hat_kind = int(ch.get("hat_kind", GameConfig.HAT_HAT))
	GameConfig.board_size = int(ch.get("size", GameConfig.STANDARD))
	# ★ 2026-11-06 第四根轴（棋盘「XX随机」）
	GameConfig.board_random_shape = bool(ch.get("random", false))


## 校验/夹取一份「上一局选项」记录，返回 `{board,size,hat_kind,diff,mode}`；
## **整份作废**（返回空字典）的条件：空记录、或棋盘 id 不是当前启用项。
## 其余字段越界一律夹回合法区间（文件被手改过也不至于崩）。
## ★ 纯函数（不碰任何节点状态）→ 两个菜单的"恢复上一局"共用同一套口径，且能被 headless 自检直接验。
##
## ★★ 对战方式只采纳 本地/人机，**「线上」一律不采纳**。理由不是偷懒，是恢复它有真实副作用：
##   菜单 `_ready()` 见到「线上」就会站到联机入口上（自建时代更硬：真的建房、可能拉起信令服务器；
##   现在是 Steam 建房 / 加入的门槛）。
##   ★ 2026-09-30 §24 第 5 步：原注释还举了一个更硬的例子 ——「随机匹配**选中即进排队队列**」。
##     那个功能（自建撮合）已随自建联机删除，现在只剩上面这一条理由。
##   ⚠️ 这条规则因此**更容易被误删**了（看着好像"没什么大不了"）。别删 ——
##     恢复「线上」会让玩家一进菜单就站在联机入口上，而他上一局只想下盘单机。
## 旧尺寸档 → 新三档。`RANDOM`(0) 是旧"随机档"（≈200 格）⇒ 归到**中档**；其余按集合取最近。
## ★ 写在函数里而不是就地 clampi：`clampi(0, SMALL, ENHANCED)` 里的范围是 3~2（**空区间**），
##   Godot 会返回下限 ⇒ 旧记录一律变"最小档"，这是静默的盘面缩水。
static func _migrate_size(sz: int) -> int:
	match sz:
		GameConfig.SMALL, GameConfig.STANDARD, GameConfig.ENHANCED:
			return sz
		GameConfig.RANDOM:
			return GameConfig.STANDARD
		_:
			return GameConfig.STANDARD


## 旧记录 → 新「随机形状」位。
## ★★ 2026-11-06：旧记录的 `size == RANDOM`(0) 语义是"自由随机盘"（盘面每局现场生成）。
##   新口径把它拆成两根轴（格数档 + 形状随机）⇒ 迁移时**必须同时置上随机位**，
##   否则老玩家的"随机盘"静默变成一张固定盘（他只会觉得"怎么每局都一样了"）。
##   ⚠️ 别把这条并进 `_migrate_size()`：那是"档位"的映射，这是"另一根轴"，两个概念。
static func _migrate_random(sz_raw: int, rand_raw: int) -> bool:
	if rand_raw != 0:
		return true
	return sz_raw == GameConfig.RANDOM


static func restore_state(d: Dictionary) -> Dictionary:
	if d.is_empty():
		return {}
	var bid: int = int(d.get("board", -1))
	if not board_id_valid(bid):
		return {}
	var md: int = int(d.get("mode", GameConfig.LOCAL))
	var sz_raw: int = int(d.get("size", GameConfig.STANDARD))
	# ★ 2026-11-06：随机形状位。`rand_shape` 是**新增可选字段**（缺 = 旧记录），
	#   旧记录里 `size == RANDOM` 就是"随机盘" ⇒ 由 `_migrate_random()` 一并迁过来。
	#   该盘没有随机版（筝形 / 爱因斯坦）时强制回落固定 —— 与 `effective_choice()` 同一口径。
	var rs: bool = _migrate_random(sz_raw, int(d.get("rand_shape", 0))) and board_has_random(bid)
	return {
		"board": bid,
		"random": rs,
		# ★★ 2026-11-06：尺寸档从 {0,1,2} 改成 {SMALL=3, STANDARD=1, ENHANCED=2} ⇒ 必须**显式迁移**
		#   旧记录：0 = 旧的"随机档"（实测约 200 格）。它在新三档里最接近**中档 13×13(≈169)**，
		#   所以映射成 STANDARD 而不是直接夹取（直接 clampi 会把 0 夹成"最小档"= 9×9，盘突然小一半）。
		#   其它越界值仍然夹回三档里最接近的那一档。
		"size": _migrate_size(sz_raw),
		"hat_kind": clampi(int(d.get("hat_kind", GameConfig.HAT_HAT)),
			GameConfig.HAT_HAT, GameConfig.HAT_SPECTRE),
		"diff": clampi(int(d.get("diff", 1)), 0, 2),
		# ★ 2026-10-13：LUDII 已退役（用户口令「彻底砍掉 Ludii」）⇒ 这里只剩 VS_AI 一个放行项。
		#   仍**不采纳** ONLINE —— 理由见函数头那段（恢复它会让人一进菜单就站在联机入口上）。
		"mode": md if md == GameConfig.VS_AI else GameConfig.LOCAL,
		# ★ 2026-10-15：「测试AI」转正为正式档「疾风」⇒ 它的选中态**跟着持久化**
		#   （否则"选了它、下完棋返回菜单又变回人机"——那不叫正式档）。
		#   夹取 0/1：文件被手改过也不至于崩（与上面 size/hat_kind 同一口径）。
		#   ★★ 2026-10-15b：桌面菜单把「疾风」并列化之后，**文件格式与本节口径都没变** ——
		#     这里仍然只在 `mode` 这一栏收发 LOCAL/VS_AI 两个值（哨兵 100 永远不进文件），
		#     疾风那一档走 `xg`。两个字段**合成 `_sel_mode` 一个状态**的活由菜单侧
		#     （`menu.gd::_apply_last_match`）干，本文件保持与手机菜单/棋谱共用的原样。
		"xg": clampi(int(d.get("xg", 0)), 0, 1),
	}


# ---------------- 显示名（手机菜单的"当前值"要用，桌面菜单也可复用） ----------------

## ⚠️ 这里**只认 `GameConfig` 层的三个 mode 值**（LOCAL/VS_AI/ONLINE）——
##   桌面菜单那个内部哨兵 `MODE_XGAI = 100` **不进这里**（它由 `menu.gd::_mode_label()`
##   在菜单侧就地给名字）。传 100 会落到 `return "?"`：那是**静默**的坏法，
##   2026-10-15b 并列化时 `_restore_last_match()` 的日志差点因此印成"对战方式=?"。
static func mode_label(m: int) -> String:
	match m:
		GameConfig.VS_AI: return "磐石"
		GameConfig.LOCAL: return "本地"
		GameConfig.ONLINE: return "线上"

	return "?"
# ⚰️ 2026-11-02 墓碑（名字不许回收）：`diff_label()` 已删除（全工程零读者，`_audit_gd` ②）。


# ★ 2026-09-30 §24 第 5 步：`netmode_label(n)` 已删除。
#   它服务的「联机方式」那一行（邀请好友 / 随机匹配）在**两个菜单**里都只剩一档 ⇒ 整行移除：
#   桌面上是那一瓣瓷砖，手机上是 `_row_defs` 里的一行。留着一个"只有一种取值"的 label 函数
#   会让 `--mtest` / `--steamuitest` 里出现"对常量做断言"的假判据。


## 手机菜单「大小」行的当前值文案。
## ★ 帽子盘下大小档**没有意义**（一律随机）→ 显示"由棋盘决定"，而不是把那个被忽略的
##   `sel_size` 显示出来让人以为能改。这条与 `effective_choice()` 同源。
## ★ 2026-11-06：帽子盘不再"由棋盘决定"（见 `effective_choice()`）⇒ 三档一视同仁。
static func size_row_value(board: int, sel_size: int) -> String:
	return size_label(sel_size, board)


# ---------------- 外观（主题预设） ----------------
# ★ 主题清单的真源是 `GameConfig.PRESETS`（2026-10-08 起 **12 个单档**；旧版是 14 个 = 7 色系 × 浅/深），
#   这里只做"展示怎么分组"，不复制任何配色，也不自己拼主题名。
#   桌面设置页排成一行（`HFlowContainer` 自动换行）、手机选项层排一节，用的都是同一套分层。
# ★★ 别在这里写死主题个数 —— 个数会随主题表改版变（14 → 12 已经发生过一次）；
#   真源是 `PRESETS.size()`，判据要断"个数对不对"请从 `GameConfig.preset_names().size()` 取。

## 主题分组标签：桌面设置页画在行首一格，手机选项层当**分节标题**。
## ★ 2026-10-08 主题改**单档**（不再分浅/深两版）⇒ 只有一组，标签是**空串**。
##   两处消费方都按「空串 ⇒ 不画标题」处理（桌面 `_build_appearance_group` / 手机 `_show_sheet`）。
## ★ 为什么保留这一层常量而不是删掉：`theme_sections()` 与桌面设置页都靠"分组"决定**排几行**；
##   留着它，将来若要再分组（例如「经典 / 霓虹」）只改这个常量 + `GameConfig.preset_name_groups()`。
##   旧名 `TIER_LABELS_SHORT/FULL` 已删 —— 单档后"tier（深浅）"这个概念不存在了（名字必须跟行为走）。
const GROUP_LABELS: Array[String] = [""]

## 主题清单的分节：[{"tier": 组号, "header": 组标签, "names": [...]}, ...]
## 顺序与 `GameConfig.preset_name_groups()` 一致。
## ★ 键名仍叫 `"tier"` 是**刻意的兼容**：手机选项层与 `--mtest` 判据都按 {header, names} 读，
##   而 "tier" 这个键目前无人读；下一轮若有人要清，请连同两层一起改（别只改这里）。
static func theme_sections() -> Array:
	var out: Array = []
	var groups: Array = GameConfig.preset_name_groups()
	for gi in groups.size():
		var names: Array = groups[gi]
		if names.is_empty():
			continue
		out.append({
			"tier": gi,
			"header": GROUP_LABELS[gi] if gi < GROUP_LABELS.size() else "",
			"names": names,
		})
	return out
# ⚰️ 2026-11-02 墓碑（名字不许回收）：`theme_row_value()` 已删除（全工程零读者，`_audit_gd` ②）。
