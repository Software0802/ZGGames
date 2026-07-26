extends Node
## 输入映射在运行时注册，而不是写进 project.godot。
##
## 理由：project.godot 里的 InputEventKey 是硬编码的 keycode 整数
## （例如 ESCAPE = 16777217），这些数字跨引擎版本没有稳定性保证，
## 手写极易出错且难以 review。用 KEY_* 枚举注册则由引擎自己保证正确。

const ACTIONS := {
	# 移动
	"move_forward": [KEY_W, KEY_UP],
	"move_back": [KEY_S, KEY_DOWN],
	"move_left": [KEY_A, KEY_LEFT],
	"move_right": [KEY_D, KEY_RIGHT],
	"run": [KEY_SHIFT],
	"jump": [KEY_SPACE],
	# 交互
	"interact": [KEY_E],          # 挤奶 / 剪毛 / 上下马 / 驱赶
	"mount": [KEY_F],
	"build_mode": [KEY_B],
	# 面板（八套界面）
	"panel_map": [KEY_M],
	"panel_herd": [KEY_H],
	"panel_settlement": [KEY_G],
	"panel_market": [KEY_T],
	"panel_appearance": [KEY_C],
	"panel_chronicle": [KEY_J],
	"panel_social": [KEY_O],
	"panel_menu": [KEY_ESCAPE],
	# 时间加速 ×1 / ×4 / ×16（交接文档 §04 WorldClock）
	"speed_1": [KEY_1],
	"speed_4": [KEY_2],
	"speed_16": [KEY_3],
	# 调试
	"debug_hud": [KEY_F3],
	"debug_freecam": [KEY_F4],
}


func _ready() -> void:
	for action_name: String in ACTIONS:
		if not InputMap.has_action(action_name):
			InputMap.add_action(action_name)
		for keycode: Key in ACTIONS[action_name]:
			var ev := InputEventKey.new()
			ev.physical_keycode = keycode
			InputMap.action_add_event(action_name, ev)
