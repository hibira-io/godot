extends Node2D
# A player in the playground: a colored dot with a name. Yours moves with the
# arrow keys / WASD or by clicking or tapping; the others' positions arrive
# through the HibiraSync child.

const SPEED := 320.0
const RADIUS := 18.0

var player_name := ""
var mine := false
var color := Color.WHITE

var _goal: Variant = null


func _ready() -> void:
	queue_redraw()


func _draw() -> void:
	draw_circle(Vector2.ZERO, RADIUS + 3.0, Color(0, 0, 0, 0.35))
	draw_circle(Vector2.ZERO, RADIUS, color)
	if mine:
		draw_arc(Vector2.ZERO, RADIUS + 6.0, 0.0, TAU, 32, Color.WHITE, 2.0)
	var font := ThemeDB.fallback_font
	var label := player_name + (" (you)" if mine else "")
	var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, 14).x
	draw_string(font, Vector2(-w / 2.0, -RADIUS - 10.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)


func _unhandled_input(event: InputEvent) -> void:
	if not mine:
		return
	# Taps arrive as mouse clicks too (emulate_mouse_from_touch is on by default).
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_goal = get_parent().get_local_mouse_position()


func _process(delta: float) -> void:
	if not mine:
		return
	var dir := Vector2(
		Input.get_axis("ui_left", "ui_right") + _key(KEY_D) - _key(KEY_A),
		Input.get_axis("ui_up", "ui_down") + _key(KEY_S) - _key(KEY_W))
	if dir != Vector2.ZERO:
		_goal = null
		position += dir.limit_length(1.0) * SPEED * delta
	elif _goal != null:
		position = position.move_toward(_goal, SPEED * delta)
		if position == _goal:
			_goal = null
	var area := get_viewport_rect().size
	position = position.clamp(Vector2(RADIUS, RADIUS + 60.0), area - Vector2(RADIUS, RADIUS))


static func _key(k: Key) -> float:
	return 1.0 if Input.is_physical_key_pressed(k) else 0.0
