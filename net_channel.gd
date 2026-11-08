class_name NetChannel
extends Node

# 对局通道契约（`SteamTransport` 是当前**唯一**实现）
# ---------------------------------------------------------------------------
# 为什么要有这个基类：
#   `game.gd` 用**一个** `_chan: NetChannel` 变量表示「本局走的是传输层通道（而不是直呼本地）」，
#   这就是全工程唯一的传输层判据。2026-09-30 之前它有两个实现（自建 TCP 中继 `RelayTransport`
#   + Steam P2P），第 5 步按用户口令「删除自建联机代码」删掉了自建中继 ⇒ **只剩 Steam 一个实现**。
#   ★ 基类**保留**（没有把它降级成 `SteamTransport` 类型），理由：它早已把调用点变成
#     "一处写、一处读" —— `game.gd` 里 11 处 `_chan.xxx()` 这次**一个字都没改**。
#     将来再加通道（例如局域网直连）也照旧：只多一个实现类，调用点零改动。
#
# ★★ 为什么**不用** Godot 高层 multiplayer（`MultiplayerPeer` / `@rpc`）：
#   Godot 4 的 `MultiplayerPeer` 是抽象类，GDScript 无法继承；
#   `MultiplayerPeerExtension` 的 `_put_packet(int,int)` 是指针式 API，GDScript 也用不了。
#   ⇒ 我们的通道是**普通 Node**，只负责"把 Dictionary 可靠地送到对端"，
#     对局层的权威判定 / 回放 / 校验全部留在 `game.gd`（`_apply_action` / `_validate_action`）。
#   ★★ 这段话**原在 `relay_transport.gd` 头部**，该文件第 5 步已移出工程根，故搬到这里保存 ——
#      它是"本工程为什么没有 RPC"的**唯一论证**。丢了它的后果不是报错，而是后来者重新引入
#      `@rpc` 并踩一遍当年的坑（第 5 步顺手删掉的那两个 `@rpc` 与 `sync_init` 就是当年的产物）。
#
# ★ 契约（实现必须满足）：
#   信号  relay_ready()                       通道就绪（**双方已到齐**，可以开始传业务数据）
#         relay_failed()                      连接失败或中断
#         message_received(msg: Dictionary)   收到对端一条消息
#   方法  send_message(msg: Dictionary)        发给对端（未就绪时**静默丢弃**，不报错）
#         is_live() -> bool                   通道是否可用
#         close_relay() -> void               主动关闭（可重复调用）
#
#   ⚠️ `start()` **故意不进基类**：各实现的入参本来就不同（Steam 要 lobby_id），
#      硬统一只会逼出"传一堆用不上的参数"这种更差的接口。各自 `start()` 契约写在各自文件头。
#
#   ⚠️ `relay_ready` 的语义是「**双方已到齐**」而不是「本端已连上」——
#      这条**必须**成立：`game.gd::_on_relay_ready()` 里房主会立刻下发初始盘面，
#      若在"对端还没来"时就触发，那份盘面会发给空气。
#
#   ★ 函数/信号名里的 `relay` 是**历史词**（自建中继时代的命名），现在不再指任何中继服务器。
#     改名要同时动基类 + `SteamTransport` + `game.gd` 十几处，收益为零，故保留。

signal relay_ready()                          # 双方都已就绪，通道可用
signal relay_failed()                         # 连接失败或中断
signal message_received(msg: Dictionary)      # 收到对端消息

## ★★ 语音旁路（2026-11-01，用户口令「加入文字和语音聊天」）—— 与 `message_received`
##   **刻意分成两条链路**，理由有三条，缺一条都会出真问题：
##   ① **可靠性相反**：业务消息必须可靠有序（落子丢一个 = 两端盘面分叉）；
##      语音必须**不可靠**（补发一个 2 秒前的音频包没有任何意义，还会把后面的包全堵住）。
##      Steam 的 send_type 是每包选的 ⇒ 两条链路各自选，不共享队列。
##   ② **通道号不同**：`SteamNet` 里语音走 `P2P_VOICE_CHANNEL`（1），业务走 0。
##      同一通道号上混发，可靠消息会被音频包挤在中间（队头阻塞），落子延迟随说话时长上涨。
##   ③ **负载形态不同**：业务是 `Dictionary` ⇒ `var_to_bytes`；语音是**裸字节**
##      （每包 323 字节），走字典会在编解码里多做一次无用的类型包装 + 多一份拷贝。
##   ⇒ 基类只留这三行：一条信号、一个发送口、一个能力探测。**默认实现 = 不支持**
##     （与 `is_live()` 默认 false 同一口径：未实现的子类不许误报"我能发语音"）。
signal voice_received(data: PackedByteArray)

## 通道是否可用（双方就绪）。默认 false —— 未实现的子类不会误报"可用"。
func is_live() -> bool:
	return false


## 主动关闭。可重复调用（第二次应是空操作）。
func close_relay() -> void:
	pass


## 发送一条消息。未就绪时应**静默丢弃**（与中继的行为一致：联机中断不该崩在发送点上）。
func send_message(_msg: Dictionary) -> void:
	pass


## 本通道能不能发语音。默认 false —— 调用方（`game.gd` 的语音按钮）必须问它，
## 不许假设"有通道就能说话"（否则按钮亮着、按下去永远没人听见，且不报错）。
func supports_voice() -> bool:
	return false


## 发送一个编码好的语音包。**未就绪 / 不支持时应静默丢弃并返回 false**（不可靠语义）。
func send_voice(_data: PackedByteArray) -> bool:
	return false
