class_name NnValue
extends RefCounted

## 价值网络（终局分差）引擎侧推理 —— `nn_value.py` 的 GDScript 端口（2026-11-07）。
##
## 【它算什么】给一个局面 + 行棋方，输出 `total_white − total_black`（**目，白方视角**，
##   正 = 白领先）。训练与离线验证见 `nn/out_value_20261027_1329_cap_h8/`：
##   留出 106 局 / 12719 局面，MAE 26.08 目（零信息线 33.44），符号一致率 0.676；
##   但真正的理由是**配对 SNR 1.52 vs 现行 `area1` 0.35**，以及把静态评估的肥尾
##   （每 10 手有 1 手让评估跳 >10 目）从 9.9% 压到 1.8%。
##
## 【权重真源】`value_weights.json`（由 `nn_value.py` 导出，`kind=value_head`）。
##   本文件**只读它**，不参与训练；任何"改模型"的事都在 Python 侧做完再导出。
##
## 【算子顺序必须逐字照抄 `ValueGNN.forward`】（`nn/nn_value.py`）：
##     h   = relu(enc(x))                                  # x = 6 维节点特征
##     agg = Σ_{u∈adj[v]} ( msg(h[u]) )                     # 双向：adj 对称
##     h   = relu(upd([ h , agg / (deg/4) ]))               # ★ 除以 deg/4，不是真均值
##     out = head([ h.mean(0) , g ]) * scale                # g = 4 维全局特征
##   ★ `agg / deg` 的 `deg` 是 `度数/4`（`DEG_DIV`）⇒ 等价于 `4 × 真均值`。
##     这一点最容易抄错，而且错了不会报错、只会让输出整体偏一个固定倍数。
##   ★ 已用 `nn/export_value_golden.py` + torch 双向核对：24 个局面最大差 1.5e-5。
##
## 【为什么自带拓扑】`deg` / `d_rim` / 邻接表**只与盘型有关**，与局面无关 ⇒
##   一次 `setup()` 全部预计算。`d_rim` 的判定与 `nn_score.gd::_compute_d_rim()`
##   完全一致（盘缘 = 度数 < 最大度数的点，多源 BFS），不是几何距离 —— 这样
##   "换了盘型"也不会让推理层依赖几何（§同名纪律）。
##
## 【速度设计】h=8 很小，瓶颈在 GDScript 的循环开销而不是乘加数。因此：
##   ① `enc` 整层折成 **查表**：`enc` 的输入里只有"颜色 one-hot"随局面变，
##      `deg/4`、`d_rim/5`、`1` 三项都是盘型常量 ⇒ 预计算 `3×n×h` 的激活前表，
##      推理时只做「按颜色取表 + relu」；
##   ② `msg` 层把「线性 + 逐边加 bias」折成 `W4 = 4·W_msg`、`b4 = 4·b_msg`，
##      于是每条边只做 **h 次加法**（求和），每点只做一次 `h×h` 乘加；
##   ③ 所有缓冲（H / M / acc）预分配复用，推理路径**零分配**。

const DEG_DIV := 4.0
const DMAX := 5.0
const PLY_DIV := 200.0

## 盘型拓扑（`setup()` 填）
var n: int = 0
var adj: Array = []                    ## Array[PackedInt32Array]，对称邻接表
var deg: PackedInt32Array = PackedInt32Array()
var deg_max: int = 0
var d_rim: PackedInt32Array = PackedInt32Array()

## 模型（`load_weights()` 填）
var ready: bool = false
var err: String = ""
var h_dim: int = 0
var layers: int = 0
var scale: float = 50.0
var weights_path: String = ""

var _w_enc: PackedFloat32Array = PackedFloat32Array()      ## [nout*nin]，行主序
var _b_enc: PackedFloat32Array = PackedFloat32Array()
var _lut: PackedFloat32Array = PackedFloat32Array()        ## [3][n][h] 激活前
var _w_msg4: Array = []                                    ## 每层 [h*h]，已 ×4
var _b_msg4: Array = []                                    ## 每层 [h]，已 ×4
var _w_upd: Array = []                                     ## 每层 [h][2h]
var _b_upd: Array = []
var _w_h1: PackedFloat32Array = PackedFloat32Array()       ## [h][h+4]
var _b_h1: PackedFloat32Array = PackedFloat32Array()
var _w_h2: PackedFloat32Array = PackedFloat32Array()       ## [1][h]
var _b_h2: float = 0.0

## 局面状态（`set_state_*` 填）
var _state: PackedInt32Array = PackedInt32Array()          ## 0=空 1=黑 2=白
var _n_empty: int = 0

## 推理缓冲（`setup()` 按 n 预分配）
var _buf_a: PackedFloat32Array = PackedFloat32Array()      ## n*h
var _buf_b: PackedFloat32Array = PackedFloat32Array()      ## n*h
var _acc: PackedFloat32Array = PackedFloat32Array()        ## h
var _m: PackedFloat32Array = PackedFloat32Array()          ## h（msg 输出，复用）
var _pooled: PackedFloat32Array = PackedFloat32Array()     ## h
var _z: PackedFloat32Array = PackedFloat32Array()          ## h+4
var _mid: PackedFloat32Array = PackedFloat32Array()        ## h

## 上次前向的耗时（µs），供仪器读；不改行为
var last_us: int = 0


## 盘型拓扑。`adjacency` 两种形态都吃：`AIEngine.adj` 是 `Array[Array]`（元素 Variant），
## `--valuetest` 从 golden 重建的是 `Array[PackedInt32Array]`。
## ★ 内部**统一复制成 `Array[PackedInt32Array]`**：热路径的邻居循环跑在最内层，
##   Variant 装箱在那里是纯浪费（`ai_engine.gd` 的 CSR 扁平化就是为同一条理由）。
func setup(adjacency: Array) -> void:
	n = adjacency.size()
	adj = []
	adj.resize(n)
	deg = PackedInt32Array()
	deg.resize(n)
	deg_max = 0
	var total := 0
	for v in n:
		var row := PackedInt32Array(adjacency[v])
		adj[v] = row
		var d := row.size()
		deg[v] = d
		total += d
		if d > deg_max:
			deg_max = d
	d_rim = _compute_d_rim()
	_state = PackedInt32Array()
	_state.resize(n)
	if h_dim > 0:
		_alloc_bufs()
		_rebuild_lut()


## 推理缓冲按 (n, h) 预分配 —— 热路径零分配。
func _alloc_bufs() -> void:
	var hh := maxi(h_dim, 1)
	_buf_a = PackedFloat32Array()
	_buf_a.resize(n * hh)
	_buf_b = PackedFloat32Array()
	_buf_b.resize(n * hh)
	_acc = PackedFloat32Array()
	_acc.resize(hh)
	_m = PackedFloat32Array()
	_m.resize(hh)
	_pooled = PackedFloat32Array()
	_pooled.resize(hh)
	_z = PackedFloat32Array()
	_z.resize(hh + 4)
	_mid = PackedFloat32Array()
	_mid.resize(hh)


## 盘缘 = 度数 < 最大度数的点（不规则密铺的边界点），到最近盘缘点的图距离。
## ★ 与 `nn_score.gd::_compute_d_rim()` 同口径；不用几何坐标，推理层与盘型无关。
func _compute_d_rim() -> PackedInt32Array:
	var dist := PackedInt32Array()
	dist.resize(n)
	dist.fill(-1)
	var q := PackedInt32Array()
	q.resize(n)
	var head_i := 0
	var tail := 0
	for v in n:
		if deg[v] < deg_max:
			dist[v] = 0
			q[tail] = v
			tail += 1
	while head_i < tail:
		var v := q[head_i]
		head_i += 1
		var nd := dist[v] + 1
		for uu in adj[v]:
			var u := int(uu)
			if dist[u] < 0:
				dist[u] = nd
				q[tail] = u
				tail += 1
	# 不连通（不该发生）：剩 -1 的点按最远处理，并留痕
	for v in n:
		if dist[v] < 0:
			dist[v] = int(DMAX)
			err = "拓扑不连通：点 %d 到不了盘缘" % v
	return dist


# ---------------------------------------------------------------------------
#  权重
# ---------------------------------------------------------------------------
func load_weights(path: String) -> bool:
	ready = false
	err = ""
	weights_path = path
	if not FileAccess.file_exists(path):
		err = "权重文件不存在：%s" % path
		return false
	var txt := FileAccess.get_file_as_string(path)
	var d: Variant = JSON.parse_string(txt)
	if typeof(d) != TYPE_DICTIONARY:
		err = "权重不是 JSON 对象：%s" % path
		return false
	if String(d.get("kind", "")) != "value_head":
		err = "kind=%s，不是 value_head" % String(d.get("kind", ""))
		return false
	if String(d.get("activation", "")) != "relu" or String(d.get("pool", "")) != "mean":
		err = "只支持 relu + mean 池化"
		return false
	h_dim = int(d.get("h", 0))
	layers = int(d.get("layers", 0))
	scale = float(d.get("scale", 50.0))
	if h_dim <= 0 or layers <= 0:
		err = "h/layers 非法：h=%d layers=%d" % [h_dim, layers]
		return false

	_w_enc = _pack_lin(d["enc"], 6, h_dim)
	_b_enc = _pack_vec(d["enc"]["b"], h_dim)

	var msgs: Array = d["msg"]
	var upds: Array = d["upd"]
	if msgs.size() != layers or upds.size() != layers:
		err = "msg/upd 层数与 layers 不一致"
		return false
	var gdin := int((d["head"][0]["W"][0] as Array).size()) - h_dim
	if gdin != 4:
		err = "全局特征维度 %d ≠ 4" % gdin
		return false

	_w_msg4 = []
	_b_msg4 = []
	_w_upd = []
	_b_upd = []
	for li in layers:
		# ★ ×4：把 torch 侧的 `agg / (deg/4)` 折进权重，逐边只剩求和（见文件头）
		var wm := _pack_lin(msgs[li], h_dim, h_dim)
		var wm4 := PackedFloat32Array()
		wm4.resize(h_dim * h_dim)
		for i in h_dim * h_dim:
			wm4[i] = wm[i] * 4.0
		_w_msg4.append(wm4)
		var bm4 := PackedFloat32Array()
		bm4.resize(h_dim)
		var bm := _pack_vec(msgs[li]["b"], h_dim)
		for i in h_dim:
			bm4[i] = bm[i] * 4.0
		_b_msg4.append(bm4)
		_w_upd.append(_pack_lin(upds[li], 2 * h_dim, h_dim))
		_b_upd.append(_pack_vec(upds[li]["b"], h_dim))

	_w_h1 = _pack_lin(d["head"][0], h_dim + gdin, h_dim)
	_b_h1 = _pack_vec(d["head"][0]["b"], h_dim)
	_w_h2 = _pack_lin(d["head"][1], h_dim, 1)
	_b_h2 = _pack_vec(d["head"][1]["b"], 1)[0]

	ready = true
	if n > 0:
		_alloc_bufs()
		_rebuild_lut()
	return true


func _pack_vec(src: Variant, k: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(k)
	for i in k:
		out[i] = float(src[i])
	return out


## 把 `nn_score.gd::_pack_lin` 同形的 `{W: [nout][nin], b: [nout]}` 展平成行主序。
func _pack_lin(d: Variant, nin: int, nout: int) -> PackedFloat32Array:
	var W: Array = d["W"]
	var out := PackedFloat32Array()
	out.resize(nout * nin)
	for o in nout:
		var row: Array = W[o]
		if row.size() != nin:
			err = "矩阵形状不符：行宽 %d ≠ %d" % [row.size(), nin]
		var base := o * nin
		for k in nin:
			out[base + k] = float(row[k])
	return out


## enc 整层折成「按颜色查表」：只有颜色 one-hot 随局面变，deg/d_rim/bias 都是盘型常量。
func _rebuild_lut() -> void:
	var hh := h_dim
	_lut = PackedFloat32Array()
	_lut.resize(3 * n * hh)
	for v in n:
		var d4: float = float(deg[v]) / DEG_DIV
		var dm: float = minf(float(d_rim[v]), DMAX) / DMAX
		for c in 3:
			var lb := (c * n + v) * hh
			for o in hh:
				var acc := _b_enc[o]
				acc += _w_enc[o * 6 + 0] * (1.0 if c == 0 else 0.0)
				acc += _w_enc[o * 6 + 1] * (1.0 if c == 1 else 0.0)
				acc += _w_enc[o * 6 + 2] * (1.0 if c == 2 else 0.0)
				acc += _w_enc[o * 6 + 3] * d4
				acc += _w_enc[o * 6 + 4] * dm
				acc += _w_enc[o * 6 + 5] * 1.0
				_lut[lb + o] = acc


# ---------------------------------------------------------------------------
#  局面
# ---------------------------------------------------------------------------
## `board[v]` 为 0/1/2（或缺失 = 0）。
func set_state_board(board: Dictionary) -> void:
	if _state.size() != n:
		_state = PackedInt32Array()
		_state.resize(n)
	var ne := 0
	for v in n:
		var c := int(board.get(v, 0))
		_state[v] = c
		if c == 0:
			ne += 1
	_n_empty = ne


## `board` = 逐点 0/1/2，值域与 `AIEngine._b` 的 `PackedByteArray` 完全一致
##（引擎侧 `EMPTY=0 / BLACK=1 / WHITE=2`）。
## ★ 存在的理由：叶子评估在热路径上，每模拟建一个 Dictionary 的分配开销会吃掉
##   实测 937µs 里相当可观的一块（`_playout()` 每模拟调一次）。
func set_state_packed(board: PackedByteArray) -> bool:
	if board.size() != n:
		err = "board 长度 %d ≠ n=%d" % [board.size(), n]
		return false
	if _state.size() != n:
		_state = PackedInt32Array()
		_state.resize(n)
	var ne := 0
	for v in n:
		var c := int(board[v])
		_state[v] = c
		if c == 0:
			ne += 1
	_n_empty = ne
	return true


## `state` = 逐点字符 '0'/'1'/'2'（与 SP 数据的 `state=` 同口径）。
func set_state_string(state: String) -> bool:
	if state.length() != n:
		err = "state 长度 %d ≠ n=%d" % [state.length(), n]
		return false
	if _state.size() != n:
		_state = PackedInt32Array()
		_state.resize(n)
	var ne := 0
	for v in n:
		var c := state.unicode_at(v) - 48
		if c < 0 or c > 2:
			err = "state[%d] 非法字符" % v
			return false
		_state[v] = c
		if c == 0:
			ne += 1
	_n_empty = ne
	return true


## 前向。`ply` = 手数（0 起），`color` = 该谁走（1=黑 2=白）。
## 返回 `total_white − total_black`（目，白方视角）。未就绪返回 0.0。
func value_of(ply: int, color: int) -> float:
	if not ready or n <= 0:
		return 0.0
	var t0 := Time.get_ticks_usec()
	var hh := h_dim
	var A := _buf_a
	var B := _buf_b

	# ---- enc：查表 + relu
	for v in n:
		var lb := (_state[v] * n + v) * hh
		var hb := v * hh
		for o in hh:
			var x := _lut[lb + o]
			A[hb + o] = x if x > 0.0 else 0.0

	# ---- 消息传递
	for li in layers:
		var wm: PackedFloat32Array = _w_msg4[li]
		var bm: PackedFloat32Array = _b_msg4[li]
		var wu: PackedFloat32Array = _w_upd[li]
		var bu: PackedFloat32Array = _b_upd[li]
		var acc := _acc
		var m := _m
		for v in n:
			# 邻域求和（折过的 ×4 让它只剩加法）
			for o in hh:
				acc[o] = 0.0
			for uu in adj[v]:
				var ub := int(uu) * hh
				for o in hh:
					acc[o] += A[ub + o]
			# torch 侧是 `agg / (deg/4)`，其中 agg = Σ(W·h + b) = W·Σh + deg·b
			#   ⇒ (W·acc + deg·b) · (4/deg) = (4W)·acc·(1/deg) + 4b
			# ★ bias 那一项**不乘 1/deg**（它已经被 deg 约掉了）。这里踩过一次：
			#   把 bias 也乘进去 ⇒ 每点偏 4b×(4/deg) ⇒ 输出整体偏百余目。
			var inv: float = 1.0 / float(deg[v])
			for o in hh:
				var wsum := 0.0
				var wb := o * hh
				for k in hh:
					wsum += wm[wb + k] * acc[k]
				m[o] = bm[o] + wsum * inv
			var vb := v * hh
			for o in hh:
				var s2 := bu[o]
				var wb2 := o * 2 * hh
				for k in hh:
					s2 += wu[wb2 + k] * A[vb + k]
					s2 += wu[wb2 + hh + k] * m[k]
				B[vb + o] = s2 if s2 > 0.0 else 0.0
		var tmp := A
		A = B
		B = tmp

	# ---- mean 池化 + 全局 4 维
	var pooled := _pooled
	for o in hh:
		pooled[o] = 0.0
	for v in n:
		var vb2 := v * hh
		for o in hh:
			pooled[o] += A[vb2 + o]
	var invn := 1.0 / float(n)
	var z := _z
	for o in hh:
		z[o] = pooled[o] * invn
	z[hh + 0] = float(ply) / PLY_DIV
	z[hh + 1] = float(ply & 1)
	z[hh + 2] = 1.0 if color == 1 else 0.0
	z[hh + 3] = float(_n_empty) / float(n)

	# ---- head：线性 → relu → 线性
	var mid := _mid
	for o in hh:
		var s3 := _b_h1[o]
		var wb3 := o * (hh + 4)
		for k in hh + 4:
			s3 += _w_h1[wb3 + k] * z[k]
		mid[o] = s3 if s3 > 0.0 else 0.0
	var out := _b_h2
	for k in hh:
		out += _w_h2[k] * mid[k]
	last_us = Time.get_ticks_usec() - t0
	return out * scale


## 只跑前向、不管木速（给对拍用；`value_of` 里已经记 last_us）。
func value_of_state(state: String, ply: int, color: int) -> float:
	if not set_state_string(state):
		return 0.0
	return value_of(ply, color)


## 引擎热路径专用：喂盘面 + 直接出分。
## ★ 长度不符返回 **NAN**（不是 0.0）——0.0 是合法评估值（盘面均势），
##   拿它当错误信号就是让"出错"和"和棋"长得一样（§138 同族）。
func value_of_packed(board: PackedByteArray, ply: int, color: int) -> float:
	if not set_state_packed(board):
		return NAN
	return value_of(ply, color)
