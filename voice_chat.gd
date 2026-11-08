class_name VoiceChat
extends Node

# 语音聊天引擎（2026-11-01，用户口令「加入文字和语音聊天」）
# ===========================================================================
# 职责边界（刻意划死，别往里加东西）：
#   本类**只做音频**——采集 → 降采样 → ADPCM 编码 → 出包；入包 → 解码 → 抖动缓冲 → 播出去。
#   它**不认识通道、不认识 Steam、不认识 `_chan`**：
#     · 出包只 `emit_signal("packet_out", bytes)`，由 `game.gd` 转给传输层；
#     · 入包只 `rx_push(bytes)`，由 `game.gd` 从传输层喂进来。
#   ⇒ 理由与 `NetChannel` 那条一致：收发两端各自只有一个写点，将来换通道（局域网直连 / WebRTC）
#     本文件一个字都不用改。反例就是把 `SteamNet.send_message` 直接写进来 —— 那样它只能在
#     Steam 下跑，而 `--chattest` 想测编解码就得先把 Steam 拉起来（不可能在 headless 里做）。
#
# ★★ 为什么自己写 ADPCM 而不用现成编码器：
#   Godot 4 没有把 Opus 编码器暴露给 GDScript（只有 `AudioStreamOggVorbis` 解码侧），
#   GDExtension 又要保证导出包随包带库。IMA-ADPCM 是 ~40 行、无依赖、4bit/样本，
#   16kHz 单声道 ⇒ **64 kbps**，正好落在 Steam P2P 不可靠包的安全预算里
#   （单包须远小于 MTU，见 `PACKET_BYTES`）。
#
# ★★ 每包**自带预测器状态**（3 字节头：predictor int16 + index uint8）：
#   丢一个包不会让后面所有包一起"越解越歪" —— 不可靠通道上这是**必须**的，
#   而代价只有 7.5%（3/323 字节）。第一版打算"包间延续状态"省掉这 3 字节，
#   那在丢包时表现为持续 0.3 秒的爆音 + 缓慢回正，听起来像"对面在刮铁"，很难归因到丢包。
#
# ★★ 采集必须走**独立 bus**（`BUS_NAME`），且该 bus 音量压到 -80dB：
#   直接把麦克风挂 Master 会把本地声音原样放出来 ⇒ 同机双开必啸叫；
#   而 `set_bus_mute(true)` 在部分平台上会让效果链提前退出（`AudioEffectCapture` 就取不到帧），
#   ⇒ 用**压音量**而不是 mute：效果链照跑，扬声器听不见。
# ===========================================================================

## 一包编好的语音（`game.gd` 收到后转给传输层，走不可靠通道）。
signal packet_out(bytes: PackedByteArray)
## 麦克风可用性变化（UI 用它在按钮上写理由，不留"点了没反应"的灰按钮）。
signal mic_state_changed(ok: bool, reason: String)
## 采集电平（0~1 的 RMS），**每个采集块一次**（约每帧）。
## ★ 设置页的电平条读它（`last_rms` 是同一个数的快照，给"拉一次就行"的调用方用）。
##   ★ 只发信号不自己画：本类不认识任何 UI（同"不认识通道"那条边界）。
signal level_changed(rms: float)
## 回放测试结束（参数 = 一共处理了多少包）。设置页用它把按钮恢复成可点。
signal loopback_finished(packets: int)

## 采样率。★ 16000 而不是引擎的 44100/48000：语音只要 300~3400Hz 的清晰度，
## 16k 已经覆盖到 8k 奈奎斯特，再高只是多花带宽。
const SAMPLE_RATE := 16000
## 一包 = 40ms。★ 定 40 而不是 20：
##   20ms 包多一倍包头开销与包数（每秒 50 个 P2P 包），而 40ms 的端到端增量延迟人耳仍不可察；
##   60ms 以上就会和落子音效错位得能听出来。
const PACKET_MS := 40
const PACKET_SAMPLES := SAMPLE_RATE * PACKET_MS / 1000      # 640
## ADPCM 4bit ⇒ 每样本半字节；包头 3 字节。
const PACKET_BYTES := 3 + PACKET_SAMPLES / 2                 # 323
## 采集 bus 的名字（自建，`_ensure_capture_bus()` 是唯一创建点）。
const BUS_NAME := "VoiceIn"

## IMA-ADPCM 标准系数表（89 项，最后一项 32767 是钳位点，表长必须恰好 89）。
const IMA_INDEX_TABLE := [-1, -1, -1, -1, 2, 4, 6, 8]
const IMA_STEP_TABLE := [
	7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
	34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
	157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
	724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024,
	3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
	15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
]
const IMA_MAX_INDEX := 88

# ---- 可调参数（工程口径：数值一律暴露，运行期可调）----
## 采集增益（1.0 = 原样）。小声说话听不清时拧它，不动编码。
@export var input_gain: float = 1.0
## 播放增益。
@export var output_gain: float = 1.0
## 抖动缓冲目标包数：收到这么多包才开始播。
## ★ 取 2（=80ms）：1 包会在网络抖动时频繁断音；3 包起延迟能听出来。
@export var jitter_packets: int = 2
## 能量门限（0 = 关，全发）。>0 时整包 RMS 低于它就**不发**（省带宽，也不把底噪送过去）。
@export var vad_rms: float = 0.0
## 判决门限：解码后样本幅度（0~1）的钳位上限。给"对面增益过大"留一个软闸。
@export var rx_clip: float = 1.0

# ---- 采集侧状态 ----
var _mic_player: AudioStreamPlayer = null
var _cap: AudioEffectCapture = null
var _bus_idx: int = -1
var _tx: bool = false
var _mic_ok: bool = false
var _mic_reason: String = "未初始化"
## 降采样：`_rs_buf` 是"已混成单声道、但还没降到 16k"的输入；
## `_rs_pos` 是下一个输出样本在它里面的**小数位置**（跨块保留 ⇒ 不是每块重新对齐）。
var _rs_buf := PackedFloat32Array()
var _rs_pos: float = 0.0
## 待编码的 16k 样本（不足一包就攒着，够了才出一包）。
var _pcm := PackedFloat32Array()
## 编码器状态（每包开头会写进包头，但**编码过程**是连续的 ⇒ 包边界没有台阶）。
var _enc_pred: int = 0
var _enc_index: int = 0

# ---- 播放侧状态 ----
var _gen: AudioStreamGenerator = null
var _player: AudioStreamPlayer = null
var _out: AudioStreamGeneratorPlayback = null
## 已解出、待播的包（`Array[PackedFloat32Array]`，先进先出）。
var _rx_q: Array = []
## 当前正在播的这一包里还没喂的余量 + 它的读位置。
var _rx_cur := PackedFloat32Array()
var _rx_cur_pos: int = 0
## 距离上一包到达过去了多久（秒）。超过 `RX_IDLE_STOP` 就停播放器，省音频线程。
var _rx_idle: float = 0.0

# ---- 统计（自检与诊断读这些，别去猜）----
var packets_sent: int = 0
var packets_recv: int = 0
var packets_muted: int = 0      # 被 VAD 挡掉的
var packets_dropped: int = 0    # 解码失败 / 空包
var frames_pushed: int = 0      # 真正喂给播放器的样本数（含补零）
## 最近一个采集块的 RMS（0~1）。设置页电平条与 `--mictest` 都读它。
var last_rms: float = 0.0
## 调试监听：只采不算（不攒包、不发包），用来"看电平 / 找设备"。
var _monitor: bool = false
## 回放测试剩余秒数（>0 = 正在录）。★ 状态机放在本类内部，菜单侧不另开定时器 ——
## 两处各计时会在切页 / 关窗口时留下"永远录着"的半截状态。
var _lb_left: float = 0.0
var _lb_pcm := PackedFloat32Array()

## 收包后多久没新包就停播放器（秒）。
const RX_IDLE_STOP := 0.6


func _ready() -> void:
	set_process(false)


# ====================================================================== 采集

## 麦克风此刻是否可用。★ 这是**探测**，不会启动采集。
func mic_available() -> bool:
	return _mic_ok


func mic_reason() -> String:
	return _mic_reason


## 项目设置里麦克风总闸是否打开了。
## ★★ 关着的时候 `AudioStreamMicrophone` 不是"没声音"，而是**引擎直接不提供输入**
##   （`AudioEffectCapture` 永远 `get_frames_available()==0`）⇒ 一句错都不报，
##   表现是"按了说话但对面听不见"。必须显式探测并把原因写出来。
func input_enabled_by_project() -> bool:
	return bool(ProjectSettings.get_setting("audio/driver/enable_input", false))


## 建/取采集 bus（唯一创建点）。返回 bus 下标，失败 -1。
func _ensure_capture_bus() -> int:
	if _bus_idx >= 0 and _bus_idx < AudioServer.bus_count:
		return _bus_idx
	var idx := AudioServer.get_bus_index(BUS_NAME)
	if idx < 0:
		idx = AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, BUS_NAME)
	# ★ 压音量而非 mute（理由见文件头）。-80dB 已是听觉上的静音。
	AudioServer.set_bus_volume_db(idx, -80.0)
	AudioServer.set_bus_mute(idx, false)
	_bus_idx = idx
	return idx


## 启动采集链路（幂等）。返回是否可用；不可用时 `mic_reason()` 给理由。
func start_capture() -> bool:
	if _mic_ok:
		return true
	if not input_enabled_by_project():
		_set_mic(false, "项目未开启麦克风输入（audio/driver/enable_input）")
		return false
	if DisplayServer.get_name() == "headless":
		# ⚠️ headless 下音频驱动是 Dummy，麦克风必然取不到帧。
		#   **必须显式写出来**：否则自检里"语音链路"看起来全绿，真机上却是哑的。
		_set_mic(false, "headless 运行（无音频驱动，采不到麦克风）")
		return false
	var idx := _ensure_capture_bus()
	if idx < 0:
		_set_mic(false, "建采集 bus 失败")
		return false
	if _mic_player == null:
		_cap = null
		for i in AudioServer.get_bus_effect_count(idx):
			var eff := AudioServer.get_bus_effect(idx, i)
			if eff is AudioEffectCapture:
				_cap = eff
				break
		if _cap == null:
			_cap = AudioEffectCapture.new()
			# ★ 缓冲 0.5s：一次 `_process` 掉帧（加载/切场景）也够用，不会把音频丢掉。
			_cap.buffer_length = 0.5
			AudioServer.add_bus_effect(idx, _cap)
		_mic_player = AudioStreamPlayer.new()
		_mic_player.name = "MicIn"
		_mic_player.stream = AudioStreamMicrophone.new()
		_mic_player.bus = BUS_NAME
		add_child(_mic_player)
		_mic_player.play()
	_set_mic(true, "")
	return true


func _set_mic(ok: bool, reason: String) -> void:
	if _mic_ok == ok and _mic_reason == reason:
		return
	_mic_ok = ok
	_mic_reason = reason
	emit_signal("mic_state_changed", ok, reason)


## 开始说话（对局里由「麦克风：开」这个开关驱动，2026-11-03 起不再是按住式）。
## 未启动采集时先启动。
func start_tx() -> bool:
	if not start_capture():
		return false
	_tx = true
	set_process(true)
	return true


## 停止说话。★ 残留的不足一包样本**保留**（不清空）：清空会在每次松手的包边界
## 制造一个 40ms 的空洞，连续短句听起来像卡带。
func stop_tx() -> void:
	_tx = false
	# 没有监听、没在回放、播放器也还没建 ⇒ 进程可以睡了（省得一帧空跑两个 if）。
	if not _monitor and _lb_left <= 0.0 and _player == null:
		set_process(false)


func is_tx() -> bool:
	return _tx


# ------------------------------------------------------- 调试：监听 / 回放 / 设备
# 这一节只服务**设置页的麦克风调试**（2026-11-01 用户口令「记得在设置里也加上麦克风调试」）。
# 它与对局链路共用同一套采集/降采样/编解码代码 —— 调试时听到的就是对面会听到的。

## 开始监听：只采不算，用来"看电平 / 找对设备"。可重复调用。
## ★ 返回 false 时 `mic_reason()` 给理由（没开 `enable_input` / headless / 建 bus 失败）。
func start_monitor() -> bool:
	if not start_capture():
		return false
	_monitor = true
	set_process(true)
	return true


func stop_monitor() -> void:
	_monitor = false
	last_rms = 0.0
	emit_signal("level_changed", 0.0)


func is_monitoring() -> bool:
	return _monitor


## 回放测试：录 `seconds` 秒，然后把整段**走一遍和联机一模一样的编解码**再播出来。
## ★ 为什么不直接把原始 PCM 播出去：那样只能证明"麦克风有信号"，
##   证明不了**编码 + 解码 + 播放**这条链是通的 —— 而真机上"对面听不见"十次有八次坏在这条链上
##   （半字节顺序、包边界状态、播放器没建起来）。这条测试就是要把它们一次性照出来。
##   ⇒ 听到的是**和对面完全一样的音质**（64kbps ADPCM）；听不清就该调 `input_gain`。
## ⚠️ **当前无 UI 入口**（2026-11-01 用户口径："设置页麦克风别搞这么专业，只要设备和阈值"
##   ⇒ 设置页那个「录制 3 秒并回放」按钮已撤）。保留它是为了**手动排查**：真机遇到
##   "对面听不见"时，临时在任意按钮里调一次 `start_loopback(3.0)` 就能听出是链坏了还是对方坏了。
##   删掉它等于下次重新写一遍（含这里记的三个坑），所以留着；但别把它当成"在用"的路径。
func start_loopback(seconds: float) -> bool:
	if not start_capture():
		return false
	_lb_pcm.clear()
	_pcm.clear()            # 别把之前攒的残渣混进回放
	_lb_left = clampf(seconds, 0.5, 10.0)
	set_process(true)
	return true
# ⚰️ 2026-11-02 墓碑（名字不许回收）：`loopback_left()` 已删除（全工程零读者，`_audit_gd` ②）。


func _finish_loopback() -> void:
	_lb_left = 0.0
	var total := _lb_pcm.size()
	var pred := 0
	var idx := 0
	var packets := 0
	var i := 0
	while i + PACKET_SAMPLES <= total:
		var chunk := _lb_pcm.slice(i, i + PACKET_SAMPLES)
		var bytes := encode_packet(chunk, pred, idx)
		var st := packet_end_state(bytes)
		pred = int(st[0])
		idx = int(st[1])
		rx_push(bytes)          # 解码 → 播放队列（与联机入站同一个口）
		packets += 1
		i += PACKET_SAMPLES
	_lb_pcm.clear()
	emit_signal("loopback_finished", packets)


# ⚰️ 2026-11-02 墓碑（名字不许回收）：`input_devices()` 已删除（全工程零读者，`_audit_gd` ②）。
#   菜单侧枚举设备走的是 `AudioServer.get_input_device_list()` 本身（`_refresh_mic_devices()`），
#   多这一层包装只会让"设备名单的真源"变成两个。
# ⚰️ 2026-11-02 墓碑（名字不许回收）：`current_input_device()` 已删除（全工程零读者，`_audit_gd` ②）。


## 切换输入设备。★ 切换后必须**重启采集**：`AudioStreamMicrophone` 在部分平台上
## 只在 `play()` 那一刻绑定设备，光改 `AudioServer.input_device` 会让采集流挂在旧设备上
## （症状：换完麦克风电平条一动不动，而没有任何报错）。
func set_input_device(dev: String) -> bool:
	AudioServer.input_device = dev
	var was_mon := _monitor
	var was_tx := _tx
	var had_mic := (_mic_player != null)
	if had_mic:
		if _mic_player.is_playing():
			_mic_player.stop()
		_mic_player.play()
	if not had_mic:
		return start_monitor() if was_mon else start_capture()
	_monitor = was_mon
	_tx = was_tx
	set_process(_monitor or _tx or _lb_left > 0.0 or _player != null)
	return true


## 把采集缓冲抽干并编码出包。`--chattest` 也用它直接喂合成样本外的真实采集帧。
func _pump_capture() -> void:
	if _cap == null or _mic_player == null:
		return
	var frames := _cap.get_frames_available()
	if frames <= 0:
		return
	_push_capture(_cap.get_buffer(frames))


## 把一帧立体声采集数据混成单声道、降到 16k，然后**按当前模式**处理：
##   · `_tx`        → 攒够一包就编码 + `packet_out`
##   · 回放测试中    → 攒进 `_lb_pcm`（等一下整段走一遍编解码再播）
##   · 仅监听       → 只更新电平，样本丢掉
## ★ 三种模式的**采样/降采样这一段是共用的**（就是下面这 30 行），不许各写一份：
##   "监听时电平对了、真发送时采样率错了"这种错只会在对面听着发闷时才发现。
func _push_capture(buf: PackedVector2Array) -> void:
	var n := buf.size()
	if n <= 0:
		return
	# 1) 混单声道 + 电平。★ 电平用**原始块**算（混完还没降采样时），
	#    降采样会按比率抽掉一部分样本、让 RMS 随引擎混音率漂 —— 那是"量具跟着环境变"。
	var start := _rs_buf.size()
	_rs_buf.resize(start + n)
	var acc := 0.0
	for i in n:
		var v := buf[i]
		var m := (v.x + v.y) * 0.5 * input_gain
		_rs_buf[start + i] = m
		acc += m * m
	last_rms = sqrt(acc / float(n))
	emit_signal("level_changed", last_rms)
	# 2) 降采样到 16k（比率用**引擎混音率**算，不写死 44100）
	var mix := float(AudioServer.get_mix_rate())
	if mix <= 0.0:
		mix = 44100.0
	var ratio := mix / float(SAMPLE_RATE)
	var out := PackedFloat32Array()
	while true:
		var i0 := int(_rs_pos)
		if i0 + 1 >= _rs_buf.size():
			break
		var f := _rs_pos - float(i0)
		out.append(lerpf(_rs_buf[i0], _rs_buf[i0 + 1], f))
		_rs_pos += ratio
	var drop := int(_rs_pos)
	if drop > 0:
		_rs_buf = _rs_buf.slice(drop)
		_rs_pos -= float(drop)
	if out.is_empty():
		return
	# 3) 按模式分发
	if _lb_left > 0.0:
		_lb_pcm.append_array(out)
		return
	if not _tx:
		return          # 仅监听：电平已经发出去了，样本到此为止
	_pcm.append_array(out)
	while _pcm.size() >= PACKET_SAMPLES:
		var chunk := _pcm.slice(0, PACKET_SAMPLES)
		_pcm = _pcm.slice(PACKET_SAMPLES)
		_emit_packet(chunk)


func _emit_packet(chunk: PackedFloat32Array) -> void:
	if vad_rms > 0.0 and _rms(chunk) < vad_rms:
		packets_muted += 1
		return
	var bytes := encode_packet(chunk, _enc_pred, _enc_index)
	# 把编码器状态留在"这一包解完时的样子"，下一包从这儿接着编
	var st := packet_end_state(bytes)
	_enc_pred = st[0]
	_enc_index = st[1]
	packets_sent += 1
	emit_signal("packet_out", bytes)


func _rms(samples: PackedFloat32Array) -> float:
	if samples.is_empty():
		return 0.0
	var acc := 0.0
	for s in samples:
		acc += s * s
	return sqrt(acc / float(samples.size()))


# ================================================================== 编码/解码

## 把一段 [-1,1] 的 16k 单声道样本编成 ADPCM 包。`pred0`/`idx0` 是起始预测器状态。
## ★ 这两个参数不设默认值、**必须显式传**：默认值会让"忘了接上状态"变成静默的包边界爆音
##   （每包都从 0 起 ⇒ 每 40ms 一次冲击），而它听起来只是"音质差"，很容易被当成编码器烂。
static func encode_packet(samples: PackedFloat32Array, pred0: int, idx0: int) -> PackedByteArray:
	var out := PackedByteArray()
	var pred := clampi(pred0, -32768, 32767)
	var idx := clampi(idx0, 0, IMA_MAX_INDEX)
	var p16 := pred & 0xFFFF
	out.append(p16 & 0xFF)
	out.append((p16 >> 8) & 0xFF)
	out.append(idx & 0xFF)
	var nib := 0
	var half := false
	for s in samples:
		var smp := int(clampf(s * 32767.0, -32768.0, 32767.0))
		var code := encode_sample(smp, pred, idx)
		pred = _next_pred(pred, code, idx)
		idx = clampi(idx + int(IMA_INDEX_TABLE[code & 7]), 0, IMA_MAX_INDEX)
		if half:
			# ★★ 顺序：**第一个样本在高 4 位**、第二个在低 4 位。
			#   这是 IMA-ADPCM 的通行排布，也是 `decode_packet()` 取码元的口径。
			#   第一版写成 `nib | (code << 4)`（首个样本落在低位）与解码端正好相反 ⇒
			#   相邻两个样本互换 ⇒ 波形高频噪声。**它不报错、长度也对、取值范围也合法**，
			#   只有 SNR 能逮到（实测 6.5dB，改对后 20+dB）。`--chattest` ⑩ 就是为它设的。
			out.append((nib << 4) | code)
			half = false
		else:
			nib = code
			half = true
	if half:
		# 样本数是偶数（`PACKET_SAMPLES` = 640）⇒ 走不到这里；留着是为了"改包长不静默丢尾巴"。
		out.append(nib)
	return out


## 单个样本 → 4bit 码（标准 IMA 量化）。**不做状态更新** —— 更新拆在 `_next_pred()`，
## 因为"更新 pred 用的 step"必须是**编码前的** step，两件事混在一处很容易写成用更新后的值。
static func encode_sample(smp: int, pred: int, idx: int) -> int:
	var step: int = IMA_STEP_TABLE[idx]
	var diff := smp - pred
	var code := 0
	if diff < 0:
		code = 8
		diff = -diff
	if diff >= step:
		code |= 4
		diff -= step
	step = step >> 1
	if diff >= step:
		code |= 2
		diff -= step
	step = step >> 1
	if diff >= step:
		code |= 1
	return code


## 由 4bit 码算出**下一步的预测值**（编码端和解码端必须用同一个公式，故抽在这里）。
static func _next_pred(pred: int, code: int, idx: int) -> int:
	var step: int = IMA_STEP_TABLE[idx]
	var dq := step >> 3
	if (code & 4) != 0:
		dq += step
	if (code & 2) != 0:
		dq += step >> 1
	if (code & 1) != 0:
		dq += step >> 2
	var next := pred - dq if (code & 8) != 0 else pred + dq
	return clampi(next, -32768, 32767)


## 一包解回 [-1,1] 的 16k 单声道样本。包头缺失/过短 ⇒ 返回空数组（调用方计一次丢包）。
static func decode_packet(bytes: PackedByteArray) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if bytes.size() < 4:
		return out
	var pred := int(bytes[0]) | (int(bytes[1]) << 8)
	if pred >= 32768:
		pred -= 65536
	var idx := clampi(int(bytes[2]), 0, IMA_MAX_INDEX)
	var n := bytes.size()
	for i in range(3, n):
		var b := int(bytes[i])
		for k in 2:
			var code := (b >> 4) if k == 0 else (b & 0xF)
			pred = _next_pred(pred, code, idx)
			idx = clampi(idx + int(IMA_INDEX_TABLE[code & 7]), 0, IMA_MAX_INDEX)
			out.append(float(pred) / 32768.0)
	return out


## 一包解完之后的编码器状态（`[pred, index]`）。
## ★ 单独抽出来是给**编码端**用的：它必须拿着"解码端会得到的那个状态"接着编，
##   否则两边状态慢慢分家 —— 症状是长句子越说越糊（而短词完全正常）。
static func packet_end_state(bytes: PackedByteArray) -> Array:
	var pred := 0
	var idx := 0
	if bytes.size() < 4:
		return [0, 0]
	pred = int(bytes[0]) | (int(bytes[1]) << 8)
	if pred >= 32768:
		pred -= 65536
	idx = clampi(int(bytes[2]), 0, IMA_MAX_INDEX)
	for i in range(3, bytes.size()):
		var b := int(bytes[i])
		for k in 2:
			var code := (b >> 4) if k == 0 else (b & 0xF)
			pred = _next_pred(pred, code, idx)
			idx = clampi(idx + int(IMA_INDEX_TABLE[code & 7]), 0, IMA_MAX_INDEX)
	return [pred, idx]


# ====================================================================== 播放

func _ensure_player() -> void:
	if _player != null:
		return
	_gen = AudioStreamGenerator.new()
	_gen.mix_rate = SAMPLE_RATE
	# 0.2s：比抖动目标（80ms）宽一档，掉帧时不至于立刻断续。
	_gen.buffer_length = 0.2
	_player = AudioStreamPlayer.new()
	_player.name = "VoiceOut"
	_player.stream = _gen
	add_child(_player)


## 立即停播并清空接收队列（「静音对方」用）。
## ★ 为什么不能靠 `RX_IDLE_STOP`（0.6s）自动收摊：静音是玩家**当场**的动作，
##   拖 0.6 秒才安静，主观上就是"我点了静音它还在响" —— 而这时玩家会以为功能坏了。
## ★ 这里只 `stop()` 不动 `_out`：`_pump_playback()` 在 `not _player.playing` 分支里会
##   重新 `play()` 并重取 `get_stream_playback()`，所以下次开口不会往失效的 playback 写。
func flush_rx() -> void:
	_rx_q.clear()
	_rx_cur = PackedFloat32Array()
	_rx_cur_pos = 0
	_rx_idle = RX_IDLE_STOP + 1.0
	if _player != null and _player.playing:
		_player.stop()


## 喂一包**编码字节**进播放队列（由 `game.gd` 从传输层转进来）。
func rx_push(bytes: PackedByteArray) -> bool:
	var pcm := decode_packet(bytes)
	if pcm.is_empty():
		packets_dropped += 1
		return false
	packets_recv += 1
	_rx_q.append(pcm)
	_rx_idle = 0.0
	# ★★ 播放器必须**在这里**建（不是在 `_pump_playback()` 里面）：
	#   第一版把 `_ensure_player()` 只写在 `_pump_playback()` 开头，而 `_process()` 又用
	#   `if _player != null:` 把整个播放泵挡住了 ⇒ 播放器永远建不出来 ⇒ **对面说话永远没声音**。
	#   而 `packets_recv` 照样涨、日志一条错都没有 —— 典型"判据绿着、功能是哑的"
	#   （`--chattest` ⑰ 就是为这一脚加的）。
	_ensure_player()
	set_process(true)
	return true


func _pump_playback(delta: float) -> void:
	if _player == null:
		return
	if _rx_idle > RX_IDLE_STOP and _player.playing:
		# 静默这么久 ⇒ 收摊。★ 不停的话播放器会一直以 16k 空转，且下次开口前
		#   `get_frames_available()` 攒了一整个 buffer 的 0 ⇒ 第一句前 0.2 秒是哑的。
		_player.stop()
		_rx_q.clear()
		_rx_cur = PackedFloat32Array()
		_rx_cur_pos = 0
		return
	if not _player.playing:
		if _queued_samples() < jitter_packets * PACKET_SAMPLES:
			return      # 还没攒够抖动缓冲，先别开口（宁可晚 80ms，不要断断续续）
		_player.play()
		_out = _player.get_stream_playback()
		if _out == null:
			return
	var avail := _out.get_frames_available()
	if avail <= 0:
		return
	var buf := PackedVector2Array()
	buf.resize(avail)
	var gain := clampf(output_gain, 0.0, 4.0)
	var lim := clampf(rx_clip, 0.01, 1.0)
	for i in avail:
		var s := _next_sample() * gain
		s = clampf(s, -lim, lim)
		buf[i] = Vector2(s, s)
	_out.push_buffer(buf)
	frames_pushed += avail


## 队列里还有多少样本（当前包余量 + 待播包）。
func _queued_samples() -> int:
	var total := (_rx_cur.size() - _rx_cur_pos)
	for p in _rx_q:
		total += (p as PackedFloat32Array).size()
	return maxi(total, 0)


func _next_sample() -> float:
	while _rx_cur_pos >= _rx_cur.size():
		if _rx_q.is_empty():
			return 0.0      # 欠载：补零（不重复上一包，重复会变成"机器人颤音"）
		_rx_cur = _rx_q.pop_front()
		_rx_cur_pos = 0
		if _rx_cur.is_empty():
			continue
	var v := _rx_cur[_rx_cur_pos]
	_rx_cur_pos += 1
	return v


func _process(delta: float) -> void:
	# 回放倒计时：到点就整段走一遍编解码播出来（状态机在本类内部，见 `start_loopback` 的注释）
	if _lb_left > 0.0:
		_lb_left -= delta
		if _lb_left <= 0.0:
			_finish_loopback()
	if _tx or _monitor or _lb_left > 0.0:
		_pump_capture()
	if _player != null:
		_rx_idle += delta
		_pump_playback(delta)


# ====================================================================== 诊断

## 播放链路是否已建起来（自检用：只读，不触发任何创建）。
## ★ 它守的是一个真实吃过的一脚：`_ensure_player()` 若只写在 `_pump_playback()` 里，
##   而 `_process()` 用 `if _player != null` 把泵挡住 ⇒ 播放器永远建不出来 ⇒
##   收包计数正常、日志干净，但**一点声音都没有**。
func has_playback() -> bool:
	return _player != null and _out != null


## 一份可打印的快照（自检 / 现场排查都读它，不要各自拼）。
func info() -> Dictionary:
	return {
		"mic_ok": _mic_ok,
		"mic_reason": _mic_reason,
		"input_bus": BUS_NAME,
		"input_setting": input_enabled_by_project(),
		"tx": _tx,
		"sent": packets_sent,
		"recv": packets_recv,
		"muted": packets_muted,
		"dropped": packets_dropped,
		"frames_pushed": frames_pushed,
		"queued": _queued_samples(),
		"sample_rate": SAMPLE_RATE,
		"packet_bytes": PACKET_BYTES,
	}


## 停止一切（回菜单 / 关场景）。★ 不 stop 的话麦克风玩家对象与采集 bus 会一直跟着
## 下一个场景活着 —— 症状是"回菜单后还在录"（用户完全看不到、也不会报错）。
func shutdown() -> void:
	_tx = false
	_monitor = false
	_lb_left = 0.0
	_lb_pcm.clear()
	last_rms = 0.0
	if _mic_player != null and is_instance_valid(_mic_player):
		_mic_player.stop()
	if _player != null and is_instance_valid(_player):
		_player.stop()
	_rx_q.clear()
	_rx_cur = PackedFloat32Array()
	_rx_cur_pos = 0
	set_process(false)
