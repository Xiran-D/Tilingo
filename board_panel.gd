class_name BoardPanel
extends RefCounted

## ═══════════════════════════════════════════════════════════════════════════
## 棋盘「盘」—— 托住棋盘的实体托盘：**几何 + 画法的唯一实现**
## ═══════════════════════════════════════════════════════════════════════════
##
## 用户 2026-10-20 两条口令：
##   ·「给棋盘一个"盘"的效果（图与面共用），记得采用主题色」
##   ·「别忘了同步设置页预览效果」
##
## 为什么要收成一份实现：设置页预览存在的意义就是"**所见即对局所得**"。
## 它跟对局盘各写一套画法，迟早长歪（本工程"两处同口径、只改一处"的坑踩过多次）。
##
## ★ 但**参数不共用**：两个盘尺度差一个数量级（对局盘整宽 ~660px，预览盘只有 ~260px）。
##   直接用绝对像素会把预览的格子吃掉一半 ⇒ pad / 厚度 / 线宽一律由调用方按自己的尺度算好传进来。
## ★ 调用方只有两个：
##     `game.gd::_draw_board_panel()`      —— 对局盘（面模式 + 图模式共用同一个函数）
##     `menu.gd::PreviewBoard._draw()`     —— 设置页预览（五角星形小盘）


## 取「盘」的形状：所有顶点 → **凸包** → 沿法向外扩 `pad`（圆角转折）。
##
## ★ 为什么是凸包，而不是"把原多边形直接外扩"：
##   · 对局盘是车轮形密铺（六瓣），外边界在凹口处**不连成单环**；
##   · 预览盘是**五角星（凹多边形）**，直接外扩只会得到"描粗的星形"，不是托盘。
##   而"盘"在物理上就是**托在底下的容器** ⇒ 凸包把凹口填平，得到的才是盘。
## ★ `JOIN_ROUND`：两个盘的外缘全是尖角，硬转折看起来像"削出来的木片"。
## ★ 早退路径都给全了：点不足 3 个 / 凸包退化 ⇒ 返回空数组，`draw()` 会直接不画。
static func shape(points: PackedVector2Array, pad: float) -> PackedVector2Array:
	if points.size() < 3:
		return PackedVector2Array()
	var hull: PackedVector2Array = Geometry2D.convex_hull(points)
	if hull.size() < 3:
		return PackedVector2Array()
	if pad <= 0.5:
		return hull
	var grown: Array = Geometry2D.offset_polygon(hull, pad, Geometry2D.JOIN_ROUND)
	if grown.size() > 0 and (grown[0] as PackedVector2Array).size() >= 3:
		return grown[0]
	return hull


## 取「盘」的形状（**圆润版**）：凸包 → 外扩 `pad` → Chaikin 细分 `iters` 轮。
##
## ★ 为什么需要这一档（2026-11-08 用户报「爱因斯坦盘的裁切不规整」）：
##   爱因斯坦盘的选区是一堆瓦片拼出来的，顶点凸包只剩**十几段长短不一的直线**，
##   硬转折全在，画出来读成「一块被随手切开的多边形」，跟盘内细密的密铺肌理打架。
##   彭罗斯是圆窗、雪花/立方体是规则多边形 —— 它们的凸包本来就该是那样，不用碰。
## ★ 顺序不能倒：**先外扩、再平滑**。Chaikin 每轮把折线往内收（收敛到内切曲线），
##   先平滑再外扩会把最外的顶点切掉 ⇒ 边缘瓦片露到盘外（背景从缝里透出来）。
##   先外扩 `pad` 再平滑，内收量远小于 `pad`（实测 2 轮 ≈ 4px < 13）⇒ 盘边恒在瓦片之外。
static func shape_round(points: PackedVector2Array, pad: float, iters: int = 2) -> PackedVector2Array:
	var poly: PackedVector2Array = shape(points, pad)
	if poly.size() < 3 or iters <= 0:
		return poly
	for _i in iters:
		poly = _chaikin(poly)
	return poly


## 取「盘」的形状（**贴合棋盘真实外轮廓**版）：给一条已经算好的闭合环，沿法向外扩 `pad`。
##
## ★ 为什么不走凸包（用户 2026-11-08 报的「裁切不规整」就是这条）：
##   凸包会把选区边缘的**凹口填平**成一大片没有格子的实心底色 —— 帽子的选区边缘本来就
##   凹凸错落，填完之后左上角能出现 2 格深的空白块，读起来像"棋盘被谁切了一刀"。
##   贴合版让盘边沿真实边界走，凹口保留 ⇒ 盘与棋盘是同一个形状，只是外面多一圈 pad。
## ★ `offset_polygon` 对凹多边形可能返回多块（凹口的角被圆化时可能断开）⇒ 取面积最大的一块。
static func shape_from_ring(ring: PackedVector2Array, pad: float, iters: int = 1) -> PackedVector2Array:
	if ring.size() < 3:
		return PackedVector2Array()
	var grown: Array = Geometry2D.offset_polygon(ring, pad, Geometry2D.JOIN_ROUND)
	var best := PackedVector2Array()
	var best_area := -1.0
	for g in grown:
		var poly: PackedVector2Array = g
		if poly.size() < 3:
			continue
		var a: float = absf(_poly_area(poly))
		if a > best_area:
			best_area = a
			best = poly
	if best.size() < 3:
		best = ring
	for _i in iters:
		best = _chaikin(best)
	return best


## 多边形有向面积的绝对值（鞋带公式；`shape_from_ring()` 挑最大块用）。
static func _poly_area(poly: PackedVector2Array) -> float:
	var a := 0.0
	var n: int = poly.size()
	for i in n:
		a += poly[i].cross(poly[(i + 1) % n])
	return a * 0.5


## Chaikin 角切割：每段取 1/4、3/4 两点（闭合折线首尾相连）。
## 新点**逐点落在原折线上的段内** ⇒ 曲线恒在原多边形内侧、且逐轮收敛到二次 B 样条，
## 不会像 Catmull-Rom 那样在尖角处往外鼓出（鼓出就会盖住相邻瓦片）。
static func _chaikin(pts: PackedVector2Array) -> PackedVector2Array:
	var n: int = pts.size()
	if n < 3:
		return pts
	var out := PackedVector2Array()
	for i in n:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % n]
		out.push_back(a.lerp(b, 0.25))
		out.push_back(a.lerp(b, 0.75))
	return out


## 画这块盘。三段，**顺序不能换**：
##   ① **厚度** —— 整块下移 `thickness`，用 `face.darkened(0.38)` 铺一层。
##      凸多边形下移后只有**下侧**露出这一条，上方被盘面自己盖住 ⇒ 不需要任何裁剪，
##      这就是 2.5D 板的标准画法（本工程 `_block_side_walls()` 同一个思路）。
##   ② **盘面** —— 颜色由调用方给（对局盘 = 主题棋盘色 × `board_panel_tint`）。
##   ③ **外轮廓** —— 让盘边"收得住"：没有它，深色棋子压在木色盘上会显得没有边界。
##
## ★ 传 `ci`：`draw_*` 系列必须落在**一个正在 `_draw()` 的 CanvasItem 实例**上，
##   静态工具自己没法画。调用方一律传 `self`。
## ★ `poly` 必须闭合吗？不用 —— 这里自己补首点成环（`draw_polyline` 不会自动闭合）。
static func draw(ci: CanvasItem, poly: PackedVector2Array, face: Color,
		thickness: float, edge: Color, edge_w: float) -> void:
	if poly.size() < 3:
		return
	if thickness > 0.5:
		var low := PackedVector2Array()
		for p in poly:
			low.push_back(p + Vector2(0.0, thickness))
		ci.draw_colored_polygon(low, face.darkened(0.38))
	ci.draw_colored_polygon(poly, face)
	var ring := poly.duplicate()
	ring.push_back(poly[0])
	ci.draw_polyline(ring, edge, maxf(edge_w, 1.0), true)


## 画一颗**圆棋子**（圆 + 同色压暗描边）—— 图模式下**对局盘与设置页预览共用**的唯一实现。
##
## ★ 描边不是装饰：圆棋子四周是空的（不像整块染色的瓷砖有格线兜着），
##   白子在浅底上只有亮度差、没有轮廓就只是一片"淡色糊"。
## ★ 描边用**同色压暗**而不是固定的格线色：霓虹 / 赛博那类主题的线是荧光色，套到棋子上会变味。
## ★ 描边 alpha 跟着棋子走（`oc.a = col.a`）：提子渐隐时不许留下一圈"空壳"。
## ★ 与 `_draw_cell()`（面模式：整块菱形染色 + 轮廓）是两套并列的画法，
##   由调用方那一侧分叉 —— 本函数只管"一颗圆棋子长什么样"，不管谁该画。
static func round_stone(ci: CanvasItem, center: Vector2, col: Color, r: float) -> void:
	if r <= 0.5:
		return
	ci.draw_circle(center, r, col)
	var ow: float = maxf(1.6, r * 0.13)
	var oc: Color = col.darkened(0.45)
	oc.a = col.a
	ci.draw_arc(center, maxf(r - ow * 0.5, 0.6), 0.0, TAU, 28, oc, ow, true)
